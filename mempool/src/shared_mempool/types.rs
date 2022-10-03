// Copyright (c) Aptos
// SPDX-License-Identifier: Apache-2.0

//! Objects used by/related to shared mempool
use crate::{
    core_mempool::CoreMempool, network::MempoolNetworkInterface,
    shared_mempool::network::MempoolNetworkSender,
};
use anyhow::Result;
use aptos_config::{
    config::{MempoolConfig, RoleType},
    network_id::{NetworkId, PeerNetworkId},
};
use aptos_crypto::HashValue;
use aptos_infallible::{Mutex, RwLock};
use aptos_types::{
    mempool_status::MempoolStatus, transaction::SignedTransaction, vm_status::DiscardedVMStatus,
};
use consensus_types::common::{RejectedTransactionSummary, TransactionSummary};
use futures::{
    channel::{mpsc, mpsc::UnboundedSender, oneshot},
    future::Future,
    task::{Context, Poll},
};
use network::{application::storage::PeerMetadataStorage, transport::ConnectionMetadata};
use serde::{Deserialize, Serialize};
use std::cmp::Ordering;
use std::{
    collections::{BTreeMap, BTreeSet, HashMap},
    fmt,
    pin::Pin,
    sync::Arc,
    task::Waker,
    time::{Instant, SystemTime},
};
use storage_interface::DbReader;
use tokio::runtime::Handle;
use vm_validator::vm_validator::TransactionValidation;

/// Struct that owns all dependencies required by shared mempool routines.
#[derive(Clone)]
pub(crate) struct SharedMempool<V>
where
    V: TransactionValidation + 'static,
{
    pub mempool: Arc<Mutex<CoreMempool>>,
    pub config: MempoolConfig,
    pub(crate) network_interface: MempoolNetworkInterface,
    pub db: Arc<dyn DbReader>,
    pub validator: Arc<RwLock<V>>,
    pub subscribers: Vec<UnboundedSender<SharedMempoolNotification>>,
}

impl<V: TransactionValidation + 'static> SharedMempool<V> {
    pub fn new(
        mempool: Arc<Mutex<CoreMempool>>,
        config: MempoolConfig,
        network_senders: HashMap<NetworkId, MempoolNetworkSender>,
        db: Arc<dyn DbReader>,
        validator: Arc<RwLock<V>>,
        subscribers: Vec<UnboundedSender<SharedMempoolNotification>>,
        role: RoleType,
        peer_metadata_storage: Arc<PeerMetadataStorage>,
    ) -> Self {
        let network_interface = MempoolNetworkInterface::new(
            peer_metadata_storage,
            network_senders,
            role,
            config.clone(),
        );
        SharedMempool {
            mempool,
            config,
            network_interface,
            db,
            validator,
            subscribers,
        }
    }

    pub fn broadcast_within_validator_network(&self) -> bool {
        self.config.shared_mempool_validator_broadcast
    }
}

#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub enum SharedMempoolNotification {
    PeerStateChange,
    NewTransactions,
    ACK,
    Broadcast,
}

pub(crate) fn notify_subscribers(
    event: SharedMempoolNotification,
    subscribers: &[UnboundedSender<SharedMempoolNotification>],
) {
    for subscriber in subscribers {
        let _ = subscriber.unbounded_send(event);
    }
}

/// A future that represents a scheduled mempool txn broadcast
pub(crate) struct ScheduledBroadcast {
    /// Time of scheduled broadcast
    deadline: Instant,
    peer: PeerNetworkId,
    backoff: bool,
    waker: Arc<Mutex<Option<Waker>>>,
}

impl ScheduledBroadcast {
    pub fn new(deadline: Instant, peer: PeerNetworkId, backoff: bool, executor: Handle) -> Self {
        let waker: Arc<Mutex<Option<Waker>>> = Arc::new(Mutex::new(None));
        let waker_clone = waker.clone();

        if deadline > Instant::now() {
            let tokio_instant = tokio::time::Instant::from_std(deadline);
            executor.spawn(async move {
                tokio::time::sleep_until(tokio_instant).await;
                let mut waker = waker_clone.lock();
                if let Some(waker) = waker.take() {
                    waker.wake()
                }
            });
        }

        Self {
            deadline,
            peer,
            backoff,
            waker,
        }
    }
}

impl Future for ScheduledBroadcast {
    type Output = (PeerNetworkId, bool); // (peer, whether this broadcast was scheduled as a backoff broadcast)

    fn poll(self: Pin<&mut Self>, context: &mut Context) -> Poll<Self::Output> {
        if Instant::now() < self.deadline {
            let waker_clone = context.waker().clone();
            let mut waker = self.waker.lock();
            *waker = Some(waker_clone);

            Poll::Pending
        } else {
            Poll::Ready((self.peer, self.backoff))
        }
    }
}

/// Message sent from QuorumStore to Mempool.
pub enum QuorumStoreRequest {
    GetBatchRequest(
        // max batch size
        u64,
        // max byte size
        u64,
        // transactions to exclude from the requested batch
        Vec<TransactionSummary>,
        // callback to respond to
        oneshot::Sender<Result<QuorumStoreResponse>>,
    ),
    /// Notifications about *rejected* committed txns.
    RejectNotification(
        // rejected transactions from consensus
        Vec<RejectedTransactionSummary>,
        // callback to respond to
        oneshot::Sender<Result<QuorumStoreResponse>>,
    ),
}

impl fmt::Display for QuorumStoreRequest {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let payload = match self {
            QuorumStoreRequest::GetBatchRequest(max_txns, max_bytes, excluded_txns, _) => {
                format!(
                    "GetBatchRequest [max_txns: {}, max_bytes: {}, excluded_txns_length: {}]",
                    max_txns,
                    max_bytes,
                    excluded_txns.len()
                )
            }
            QuorumStoreRequest::RejectNotification(rejected_txns, _) => {
                format!(
                    "RejectNotification [rejected_txns_length: {}]",
                    rejected_txns.len()
                )
            }
        };
        write!(f, "{}", payload)
    }
}

/// Response sent from mempool to consensus.
#[derive(Debug)]
pub enum QuorumStoreResponse {
    /// Block to submit to consensus
    GetBatchResponse(Vec<SignedTransaction>),
    CommitResponse(),
}

pub type SubmissionStatus = (MempoolStatus, Option<DiscardedVMStatus>);

pub type SubmissionStatusBundle = (SignedTransaction, SubmissionStatus);

pub enum MempoolClientRequest {
    SubmitTransaction(SignedTransaction, oneshot::Sender<Result<SubmissionStatus>>),
    GetTransactionByHash(HashValue, oneshot::Sender<Option<SignedTransaction>>),
}

pub type MempoolClientSender = mpsc::Sender<MempoolClientRequest>;
pub type MempoolEventsReceiver = mpsc::Receiver<MempoolClientRequest>;

/// State of last sync with peer:
/// `timeline_id` is position in log of ready transactions
/// `is_alive` - is connection healthy
#[derive(Clone, Debug)]
pub(crate) struct PeerSyncState {
    pub timeline_id: TimelineId,
    pub broadcast_info: BroadcastInfo,
    pub metadata: ConnectionMetadata,
}

// TODO: pass in number of buckets to initialize timeline_id instead of None?
impl PeerSyncState {
    pub fn new(metadata: ConnectionMetadata, num_broadcast_buckets: usize) -> Self {
        PeerSyncState {
            timeline_id: TimelineId::new(num_broadcast_buckets),
            broadcast_info: BroadcastInfo::new(),
            metadata,
        }
    }
}

/// Identifier for a broadcasted batch of txns.
/// For BatchId(`start_id`, `end_id`), (`start_id`, `end_id`) is the range of timeline IDs read from
/// the core mempool timeline index that produced the txns in this batch.
#[derive(Clone, Copy, Debug, Deserialize, Eq, Hash, PartialEq, Serialize)]
struct BatchId(pub u64, pub u64);

impl PartialOrd for BatchId {
    fn partial_cmp(&self, other: &BatchId) -> Option<std::cmp::Ordering> {
        Some((other.0, other.1).cmp(&(self.0, self.1)))
    }
}

impl Ord for BatchId {
    fn cmp(&self, other: &BatchId) -> std::cmp::Ordering {
        (other.0, other.1).cmp(&(self.0, self.1))
    }
}

#[derive(Clone, Debug, Deserialize, Eq, Hash, PartialEq, Serialize)]
pub struct TimelineId(pub Vec<u64>);

impl TimelineId {
    pub(crate) fn new(num_buckets: usize) -> Self {
        Self(vec![0; num_buckets])
    }

    pub(crate) fn update(&mut self, batch_id: &MultiBatchId) {
        if self.0.len() != batch_id.0.len() {
            return;
        }

        let updated: Vec<_> = self
            .0
            .iter()
            .zip(batch_id.0.iter())
            .map(|(&cur, &(_start, end))| std::cmp::max(cur, end))
            .collect();

        self.0 = updated;
    }
}

impl From<Vec<u64>> for TimelineId {
    fn from(vector: Vec<u64>) -> Self {
        Self(vector)
    }
}

#[derive(Clone, Debug, Deserialize, Eq, Hash, PartialEq, Serialize)]
pub struct MultiBatchId(pub Vec<(u64, u64)>);

impl MultiBatchId {
    pub(crate) fn from_timeline_ids(old: &TimelineId, new: &TimelineId) -> Self {
        Self(old.0.iter().cloned().zip(new.0.iter().cloned()).collect())
    }
}

// Note: in rev order to check significant pairs first
impl PartialOrd for MultiBatchId {
    fn partial_cmp(&self, other: &MultiBatchId) -> Option<std::cmp::Ordering> {
        for (&self_pair, &other_pair) in self.0.iter().rev().zip(other.0.iter().rev()) {
            let ordering = self_pair.cmp(&other_pair);
            if ordering != Ordering::Equal {
                return Some(ordering);
            }
        }
        Some(Ordering::Equal)
    }
}

impl Ord for MultiBatchId {
    fn cmp(&self, other: &MultiBatchId) -> std::cmp::Ordering {
        for (&self_pair, &other_pair) in self.0.iter().rev().zip(other.0.iter().rev()) {
            let ordering = self_pair.cmp(&other_pair);
            if ordering != Ordering::Equal {
                return ordering;
            }
        }
        Ordering::Equal
    }
}

/// Txn broadcast-related info for a given remote peer.
#[derive(Clone, Debug)]
pub struct BroadcastInfo {
    // Sent broadcasts that have not yet received an ack.
    pub sent_batches: BTreeMap<MultiBatchId, SystemTime>,
    // Broadcasts that have received a retry ack and are pending a resend.
    pub retry_batches: BTreeSet<MultiBatchId>,
    // Whether broadcasting to this peer is in backoff mode, e.g. broadcasting at longer intervals.
    pub backoff_mode: bool,
}

impl BroadcastInfo {
    fn new() -> Self {
        Self {
            sent_batches: BTreeMap::new(),
            retry_batches: BTreeSet::new(),
            backoff_mode: false,
        }
    }
}
