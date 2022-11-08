// TODO(grao): Write module documentation.
module aptos_std::smart_tree {
    use aptos_std::table_with_length::{Self, TableWithLength};
    use std::option::{Self, Option};
    use std::vector;
    use std::debug;
    use aptos_std::string;

    const E_UNKNOWN: u64 = 0;
    const E_TREE_NOT_EMPTY: u64 = 1;
    const E_TREE_TOO_BIG: u64 = 2;
    const E_END_ITERATOR: u64 = 3;

    const NULL_INDEX: u64 = 0;

    const DEFAULT_ORDER : u8 = 32;

    struct Node has drop, store {
        is_leaf: bool,
        parent: u64,
        children: vector<Child>,
        prev: u64,
        next: u64,
    }

    struct Child has copy, drop, store {
        max_key: u64,
        index: u64,
    }

    struct Iterator has copy, drop {
        node_index: u64,
        key_index: u64,
        key: u64,
    }

    struct SmartTree<phantom V> has store {
        root: u64,
        // TODO(grao): Update to use bucket table.
        nodes: TableWithLength<u64, Node>,
        entries: TableWithLength<u64, V>,
        order: u8,
        min_leaf_index: u64,
        max_leaf_index: u64,
    }

    /////////////////////////////////
    // Constructors && Destructors //
    /////////////////////////////////

    /// Returns a new SmartTree with the default order.
    public fun new<V: store>(): SmartTree<V> {
        new_with_order(DEFAULT_ORDER)
    }

    /// Returns a new SmartTree with the provided order.
    public fun new_with_order<V: store>(order: u8): SmartTree<V> {
        assert!(order >= 5, E_UNKNOWN);
        let root_node = new_node(/*is_leaf=*/true, /*parent=*/NULL_INDEX);
        let nodes = table_with_length::new();
        let root_index = 1;
        table_with_length::add(&mut nodes, root_index, root_node);
        SmartTree {
            root: root_index,
            nodes: nodes,
            entries: table_with_length::new(),
            order: order,
            min_leaf_index: root_index,
            max_leaf_index: root_index,
        }
    }

    /// Destroys the tree if it's empty, otherwise aborts.
    public fun destroy_empty<V>(tree: SmartTree<V>) {
        let SmartTree { entries, nodes, root, order: _, min_leaf_index: _, max_leaf_index: _ } = tree;
        assert!(table_with_length::empty(&entries), E_TREE_NOT_EMPTY);
        assert!(table_with_length::length(&nodes) == 1, E_TREE_NOT_EMPTY);
        table_with_length::remove(&mut nodes, root);
        table_with_length::destroy_empty(nodes);
        table_with_length::destroy_empty(entries);
    }

    ///////////////
    // Modifiers //
    ///////////////

    /// Inserts the key/value into the SmartTree.
    /// Aborts if the key is already in the tree.
    public fun insert<V>(tree: &mut SmartTree<V>, key: u64, value: V) {
        assert!(size(tree) < 1048576, E_TREE_TOO_BIG);

        print(b"--------------------------------------[Insert] ");
        debug::print(&key);
        table_with_length::add(&mut tree.entries, key, value);

        let leaf = find_leaf(tree, key);

        if (leaf == NULL_INDEX) {
            // In this case, the key is greater than all keys in the tree.
            leaf = tree.max_leaf_index;
            let current = table_with_length::borrow(&tree.nodes, leaf).parent;
            while (current != NULL_INDEX) {
                let current_node = table_with_length::borrow_mut(&mut tree.nodes, current);
                let last_index = vector::length(&current_node.children) - 1;
                let last_element = vector::borrow_mut(&mut current_node.children, last_index);
                last_element.max_key = key;
                current = current_node.parent;
            }
        };

        insert_at(tree, leaf, new_child(key, NULL_INDEX));
    }

    /// If the key doesn't exist in the tree, inserts the key/value, and returns none.
    /// Otherwise updates the value under the given key, and returns the old value.
    public fun upsert<V>(tree: &mut SmartTree<V>, key: u64, value: V): Option<V> {
        if (!table_with_length::contains(&tree.entries, key)) {
            insert(tree, key, value);
            return option::none()
        };

        let old_value = table_with_length::remove(&mut tree.entries, key);
        table_with_length::add(&mut tree.entries, key, value);
        option::some(old_value)
    }

    /// Removes the entry from SmartTree and returns the value which `key` maps to.
    /// Aborts if there is no entry for `key`.
    public fun remove<V>(tree: &mut SmartTree<V>, key: u64): V {
        print(b"--------------------------------------[Remove] ");
        debug::print(&key);
        let value = table_with_length::remove(&mut tree.entries, key);
        let leaf = find_leaf(tree, key);
        assert!(leaf != NULL_INDEX, E_UNKNOWN);

        remove_at(tree, leaf, key);
        value
    }

    ///////////////
    // Accessors //
    ///////////////

    // Returns true iff the node_index is NULL_INDEX. 
    public fun is_null_index(node_index: u64): bool {
        node_index == NULL_INDEX
    }

    // Returns true iff the iterator is an end iterator. 
    public fun is_end_iter<V>(_tree: &SmartTree<V>, iter: &Iterator): bool {
        iter.node_index == NULL_INDEX
    }

    /// Returns an iterator pointing to the first element that is greater or equal to the provided
    /// key, or an end iterator if such element doesn't exist.
    public fun lower_bound<V>(tree: &SmartTree<V>, key: u64): Iterator {
        let leaf = find_leaf(tree, key);
        if (leaf == NULL_INDEX) {
            return new_end_iter(tree)
        };

        let node = table_with_length::borrow(&tree.nodes, leaf);
        assert!(node.is_leaf, E_UNKNOWN);

        let keys = &node.children;

        let len = vector::length(keys);

        let l = 0;
        let r = len;

        while (l != r) {
            let mid = l + (r - l) / 2;
            if (vector::borrow(keys, mid).max_key < key) {
                l = mid + 1;
            } else {
                r = mid;
            };
        };

        new_iter(leaf, l, vector::borrow(keys, l).max_key)
    }

    /// Returns an iterator pointing to the element that equals to the provided key, or an end
    /// iterator if the key is not found.
    public fun find<V>(tree: &SmartTree<V>, key: u64): Iterator {
        print(b"--------------------------------------[find] ");
        debug::print(&key);
        if (!table_with_length::contains(&tree.entries, key)) {
            return new_end_iter(tree)
        };

        lower_bound(tree, key)
    }

    /// Returns true iff the key exists in the tree.
    public fun contains<V>(tree: &SmartTree<V>, key: u64): bool {
        table_with_length::contains(&tree.entries, key)
    }

    /// Returns the key of the given iterator.
    public fun get_key(iter: Iterator): u64 {
        assert!(iter.node_index != NULL_INDEX, E_END_ITERATOR);
        iter.key
    }

    /// Returns a reference to the element with its key, aborts if the key is not found.
    public fun borrow<V>(tree: &SmartTree<V>, key: u64): &V {
        table_with_length::borrow(&tree.entries, key)
    }

    /// Returns a mutable reference to the element with its key at the given index, aborts if the key is not found.
    public fun borrow_mut<V>(tree: &mut SmartTree<V>, key: u64): &mut V {
        table_with_length::borrow_mut(&mut tree.entries, key)
    }

    /// Returns the number of elements in the SmartTree.
    public fun size<V>(tree: &SmartTree<V>): u64 {
        table_with_length::length(&tree.entries)
    }

    /// Returns true iff the SmartTree is empty.
    public fun empty<V>(tree: &SmartTree<V>): bool {
        table_with_length::length(&tree.entries) == 0
    }

    /// Return the begin iterator.
    public fun new_begin_iter<V>(tree: &SmartTree<V>): Iterator {
        if (empty(tree)) {
            return new_iter(NULL_INDEX, 0, 0)
        };

        let node = table_with_length::borrow(&tree.nodes, tree.min_leaf_index);
        let key = vector::borrow(&node.children, 0).max_key;

        new_iter(tree.min_leaf_index, 0, key)
    }

    /// Return the end iterator.
    public fun new_end_iter<V>(_tree: &SmartTree<V>): Iterator {
        new_iter(NULL_INDEX, 0, 0)
    }

    /// Returns the next iterator, or none if already at the end iterator.
    /// Requires the tree is not changed after the input iterator is generated.
    public fun next_iter<V>(tree: &SmartTree<V>, iter: Iterator): Option<Iterator> {
        let node_index = iter.node_index;
        if (node_index == NULL_INDEX) {
            return option::none()
        };

        let node = table_with_length::borrow(&tree.nodes, node_index);
        iter.key_index = iter.key_index + 1;
        if (iter.key_index < vector::length(&node.children)) {
            iter.key = vector::borrow(&node.children, iter.key_index).max_key;
            return option::some(iter)
        };

        let next_index = node.next;
        if (next_index != NULL_INDEX) {
            let next_node = table_with_length::borrow(&tree.nodes, next_index);
            iter.node_index = next_index;
            iter.key_index = 0;
            iter.key = vector::borrow(&next_node.children, 0).max_key;
            return option::some(iter)
        };

        option::some(new_end_iter(tree))
    }

    /// Returns the previous iterator, or none if already at the begin iterator.
    /// Requires the tree is not changed after the input iterator is generated.
    public fun prev_iter<V>(tree: &SmartTree<V>, iter: Iterator): Option<Iterator> {
        let node_index = iter.node_index;

        let prev_index;

        if (node_index == NULL_INDEX) {
            prev_index = tree.max_leaf_index;
        } else {
            let node = table_with_length::borrow(&tree.nodes, node_index);
            iter.key_index = iter.key_index - 1;
            if (iter.key_index >= 0) {
                iter.key = vector::borrow(&node.children, iter.key_index).max_key;
                return option::some(iter)
            };
            prev_index = node.prev;
        };

        if (prev_index != NULL_INDEX) {
            let prev_node = table_with_length::borrow(&tree.nodes, prev_index);
            let len = vector::length(&prev_node.children);
            iter.node_index = prev_index;
            iter.key_index = len - 1;
            iter.key = vector::borrow(&prev_node.children, len - 1).max_key;
            return option::some(iter)
        };

        option::none()
    }


    //////////////////////////////
    // Internal Implementations //
    //////////////////////////////

    fun new_node(is_leaf: bool, parent: u64): Node {
        Node {
            is_leaf: is_leaf,
            parent: parent,
            children: vector::empty(),
            prev: NULL_INDEX,
            next: NULL_INDEX,
        }
    }

    fun new_child(max_key: u64, index: u64): Child {
        Child {
            max_key: max_key,
            index: index,
        }
    }

    fun new_iter(node_index: u64, key_index: u64, key: u64): Iterator {
        Iterator {
            node_index: node_index,
            key_index: key_index,
            key: key,
        }
    }

    fun find_leaf<V>(tree: &SmartTree<V>, key: u64): u64 {
        let current = tree.root;
        while (current != NULL_INDEX) {
            let node = table_with_length::borrow(&tree.nodes, current);
            if (node.is_leaf) {
                return current
            };
            let len = vector::length(&node.children);
            assert!(len != 0, E_UNKNOWN);
            if (vector::borrow(&node.children, len - 1).max_key < key) {
                return NULL_INDEX
            };

            let l = 0;
            let r = len;
            while (l != r) {
                let mid = l + (r - l) / 2;
                if (vector::borrow(&node.children, mid).max_key < key) {
                    l = mid + 1;
                } else {
                    r = mid;
                };
            };

            current = vector::borrow(&node.children, l).index;
        };

        NULL_INDEX
    }

    fun insert_at<V>(tree: &mut SmartTree<V>, node_index: u64, child: Child) {
        let node = table_with_length::remove(&mut tree.nodes, node_index);
        let parent_index = node.parent;
        let children = &mut node.children;
        let is_leaf = &mut node.is_leaf;
        let next = &mut node.next;
        let prev = &mut node.prev;
        let current_size = vector::length(children);
        let key = child.max_key;

        if (current_size < (tree.order as u64)) {
            // Do not need to split.
            let i = current_size;
            vector::push_back(children, new_child(0, 0));
            while (i > 0) {
                let previous_child = vector::borrow(children, i - 1);
                if (previous_child.max_key < key) {
                    break
                };
                *vector::borrow_mut(children, i) = *previous_child;
                i = i - 1;
            };
            *vector::borrow_mut(children, i) = child;
            table_with_length::add(&mut tree.nodes, node_index, node);
            return
        };

        // # of children in the current node exceeds the threshold, need to split into two nodes.

        let target_size = ((tree.order as u64) + 1) / 2;

        let l = 0;
        let r = current_size;
        while (l != r) {
            let mid = l + (r - l) / 2;
            if (vector::borrow(children, mid).max_key < key) {
                l = mid + 1;
            } else {
                r = mid;
            };
        };

        let left_node_index = table_with_length::length(&tree.nodes) + 2;

        if (parent_index == NULL_INDEX) {
            // Splitting root now, need to create a new root.
            parent_index = table_with_length::length(&tree.nodes) + 3;
            node.parent = parent_index;

            tree.root = parent_index;
            let parent_node = new_node(/*is_leaf=*/false, /*parent=*/NULL_INDEX);
            let max_element = vector::borrow(children, current_size - 1).max_key;
            if (max_element < key) {
                max_element = key;
            };
            vector::push_back(&mut parent_node.children, new_child(max_element, node_index));
            table_with_length::add(&mut tree.nodes, parent_index, parent_node);
        };

        let right_node = new_node(*is_leaf, parent_index);
        
        right_node.next = *next;
        *next = node_index;
        right_node.prev = left_node_index;
        if (*prev != NULL_INDEX) {
            table_with_length::borrow_mut(&mut tree.nodes, *prev).next = left_node_index;
        };

        if (l < target_size) {
            let i = target_size - 1;
            while (i < current_size) {
                vector::push_back(&mut right_node.children, *vector::borrow(children, i));
                i = i + 1;
            };

            while (current_size > target_size) {
                vector::pop_back(children);
                current_size = current_size - 1;
            };

            i = target_size - 1;
            while (i > l) {
                *vector::borrow_mut(children, i) = *vector::borrow(children, i - 1);
                i = i - 1;
            };
            *vector::borrow_mut(children, l) = child;
        } else {
            let i = target_size;
            while (i < l) {
                vector::push_back(&mut right_node.children, *vector::borrow(children, i));
                i = i + 1;
            };
            vector::push_back(&mut right_node.children, child);
            while (i < current_size) {
                vector::push_back(&mut right_node.children, *vector::borrow(children, i));
                i = i + 1;
            };

            while (current_size > target_size) {
                vector::pop_back(children);
                current_size = current_size - 1;
            };
        };

        if (!*is_leaf) {
            let i = 0;
            while (i < target_size) {
                table_with_length::borrow_mut(&mut tree.nodes, vector::borrow(children, i).index).parent = left_node_index;
                i = i + 1;
            };
        };

        let split_key = vector::borrow(children, target_size - 1).max_key;

        print(b"Adding nodes:");
        debug::print(&left_node_index);
        debug::print(&node);
        debug::print(&node_index);
        debug::print(&right_node);

        table_with_length::add(&mut tree.nodes, left_node_index, node);
        table_with_length::add(&mut tree.nodes, node_index, right_node);
        if (node_index == tree.min_leaf_index) {
            tree.min_leaf_index = left_node_index;
        };
        insert_at(tree, parent_index, new_child(split_key, left_node_index));
    }

    fun update_key<V>(tree: &mut SmartTree<V>, node_index: u64, old_key: u64, new_key: u64) {
        if (node_index == NULL_INDEX) {
            return
        };

        let node = table_with_length::borrow_mut(&mut tree.nodes, node_index);
        let keys = &mut node.children;
        let current_size = vector::length(keys);

        let l = 0;
        let r = current_size;

        while (l != r) {
            let mid = l + (r - l) / 2;
            if (vector::borrow(keys, mid).max_key < old_key) {
                l = mid + 1;
            } else {
                r = mid;
            };
        };

        vector::borrow_mut(keys, l).max_key = new_key;
        move keys;

        if (l == current_size - 1) {
            update_key(tree, node.parent, old_key, new_key);
        };
    }

    fun remove_at<V>(tree: &mut SmartTree<V>, node_index: u64, key: u64) {
        let node = table_with_length::remove(&mut tree.nodes, node_index);
        let prev = node.prev;
        let next = node.next;
        let parent = node.parent;
        let is_leaf = node.is_leaf;

        let children = &mut node.children;
        let current_size = vector::length(children);

        if (current_size == 1) {
            // Remove the only element at root node.
            assert!(node_index == tree.root, E_UNKNOWN);
            assert!(key == vector::borrow(children, 0).max_key, E_UNKNOWN);
            vector::pop_back(children);
            table_with_length::add(&mut tree.nodes, node_index, node);
            return
        };

        let l = 0;
        let r = current_size;

        while (l != r) {
            let mid = l + (r - l) / 2;
            if (vector::borrow(children, mid).max_key < key) {
                l = mid + 1;
            } else {
                r = mid;
            };
        };

        current_size = current_size - 1;

        if (l == current_size) {
            update_key(tree, parent, key, vector::borrow(children, l - 1).max_key);
        };

        while (l < current_size) {
            *vector::borrow_mut(children, l) = *vector::borrow(children, l + 1);
            l = l + 1;
        };
        vector::pop_back(children);

        if (current_size * 2 >= (tree.order as u64)) {
            table_with_length::add(&mut tree.nodes, node_index, node);
            return
        };

        if (node_index == tree.root) {
            if (current_size == 1 && !is_leaf) {
                tree.root = vector::borrow(children, 0).index;
            } else {
                table_with_length::add(&mut tree.nodes, node_index, node);
            };
            return
        };

        // Children size is below threshold.

        let brother_index = next;
        if (brother_index == NULL_INDEX || table_with_length::borrow(&tree.nodes, brother_index).parent != parent) {
            brother_index = prev;
        };
        let brother_node = table_with_length::remove(&mut tree.nodes, brother_index);
        let brother_children = &mut brother_node.children;
        let brother_size = vector::length(brother_children);

        if ((brother_size - 1) * 2 >= (tree.order as u64)) {
            // The bother node has enough elements, borrow an element from the brother node.
            brother_size = brother_size - 1;
            if (brother_index == next) {
                let borrowed_element = *vector::borrow(brother_children, 0);
                vector::push_back(children, borrowed_element);
                if (borrowed_element.index != NULL_INDEX) {
                    table_with_length::borrow_mut(&mut tree.nodes, borrowed_element.index).parent = node_index;
                };
                let i = 0;
                while (i < brother_size) {
                    *vector::borrow_mut(brother_children, i) = *vector::borrow(brother_children, i + 1);
                    i = i + 1;
                };
                vector::pop_back(brother_children);
                update_key(tree, parent, vector::borrow(children, current_size - 2).max_key, borrowed_element.max_key);
            } else {
                let i = current_size;
                while (i > 0) {
                    *vector::borrow_mut(children, i) = *vector::borrow(children, i - 1);
                    i = i - 1;
                };
                let borrowed_element = vector::pop_back(brother_children);
                if (borrowed_element.index != NULL_INDEX) {
                    table_with_length::borrow_mut(&mut tree.nodes, borrowed_element.index).parent = node_index;
                };
                *vector::borrow_mut(children, 0) = borrowed_element; 
                update_key(tree, parent, vector::borrow(children, 0).max_key, vector::borrow(brother_children, brother_size - 1).max_key);
            };

            print(b"Add both self and brother: ");
            debug::print(&node_index);
            debug::print(&node);
            debug::print(&brother_index);
            debug::print(&brother_node);

            table_with_length::add(&mut tree.nodes, node_index, node);
            table_with_length::add(&mut tree.nodes, brother_index, brother_node);
            return
        };

        // The bother node doesn't have enough elements to borrow, merge with the brother node.
        if (brother_index == next) {
            if (!is_leaf) {
                let len = vector::length(children);
                let i = 0;
                while (i < len) {
                    table_with_length::borrow_mut(&mut tree.nodes, vector::borrow(children, i).index).parent = brother_index;
                    i = i + 1;
                };
            };
            vector::append(children, brother_node.children);
            node.next = brother_node.next;
            let key_to_remove = vector::borrow(children, current_size - 1).max_key;

            move children;

            if (node.next != NULL_INDEX) {
                table_with_length::borrow_mut(&mut tree.nodes, node.next).prev = brother_index;
            };
            if (node.prev != NULL_INDEX) {
                table_with_length::borrow_mut(&mut tree.nodes, node.prev).next = brother_index;
            };

            print(b"Add merged node: ");
            debug::print(&brother_index);
            debug::print(&node);

            table_with_length::add(&mut tree.nodes, brother_index, node);
            if (tree.min_leaf_index == node_index) {
                tree.min_leaf_index = brother_index;
            };

            if (parent != NULL_INDEX) {
                remove_at(tree, parent, key_to_remove);
            };
        } else {
            if (!is_leaf) {
                let len = vector::length(brother_children);
                let i = 0;
                while (i < len) {
                    table_with_length::borrow_mut(&mut tree.nodes, vector::borrow(brother_children, i).index).parent = node_index;
                    i = i + 1;
                };
            };
            vector::append(brother_children, node.children);
            brother_node.next = node.next;
            let key_to_remove = vector::borrow(brother_children, brother_size - 1).max_key;

            move brother_children;

            if (brother_node.next != NULL_INDEX) {
                table_with_length::borrow_mut(&mut tree.nodes, brother_node.next).prev = node_index;
            };
            if (brother_node.prev != NULL_INDEX) {
                table_with_length::borrow_mut(&mut tree.nodes, brother_node.prev).next = node_index;
            };

            print(b"Add merged node: ");
            debug::print(&node_index);
            debug::print(&brother_node);

            table_with_length::add(&mut tree.nodes, node_index, brother_node);
            if (tree.min_leaf_index == brother_index) {
                tree.min_leaf_index = node_index;
            };

            if (parent != NULL_INDEX) {
                remove_at(tree, parent, key_to_remove);
            };
        }
    }

    // TODO(grao): Remove
    fun print(s: vector<u8>) {
        debug::print(&string::utf8(s));
    }

    ///////////
    // Tests //
    ///////////

    #[test_only]
    fun destroy<V: drop>(tree: SmartTree<V>) {
        let it = new_begin_iter(&tree);
        while (!is_end_iter(&tree, &it)) {
            remove(&mut tree, it.key);
            assert!(is_end_iter(&tree, &find(&tree, it.key)), E_UNKNOWN);
            it = new_begin_iter(&tree);
            validate_tree(&tree);
        };

        destroy_empty(tree);
    }

    #[test_only]
    fun validate_subtree<V>(tree: &SmartTree<V>, node_index: u64, expected_max_key: Option<u64>) {
        let node = table_with_length::borrow(&tree.nodes, node_index);
        let len = vector::length(&node.children);

        let i = 1;
        while (i < len) {
            assert!(vector::borrow(&node.children, i).max_key > vector::borrow(&node.children, i - 1).max_key, E_UNKNOWN);
            i = i + 1;
        };

        if (!node.is_leaf) {
            let i = 0;
            while (i < len) {
                let child = vector::borrow(&node.children, i);
                validate_subtree(tree, child.index, option::some(child.max_key));
                i = i + 1;
            };
        };

        if (option::is_some(&expected_max_key)) {
            let expected_max_key = option::extract(&mut expected_max_key);
            assert!(expected_max_key == vector::borrow(&node.children, len - 1).max_key, E_UNKNOWN);
        };
    }

    #[test_only]
    fun validate_tree<V>(tree: &SmartTree<V>) {
        validate_subtree(tree, tree.root, option::none());
    }

    #[test]
    fun test_smart_tree() {
        let tree = new_with_order(5);
        insert(&mut tree, 1, 1);
        insert(&mut tree, 2, 2);
        assert!(upsert(&mut tree, 3, 3) == option::none(), E_UNKNOWN);
        insert(&mut tree, 4, 4);
        assert!(upsert(&mut tree, 4, 8) == option::some(4), E_UNKNOWN);
        insert(&mut tree, 5, 5);
        insert(&mut tree, 6, 6);

        remove(&mut tree, 5);
        remove(&mut tree, 4);
        remove(&mut tree, 1);
        remove(&mut tree, 3);
        remove(&mut tree, 2);
        remove(&mut tree, 6);

        destroy_empty(tree);
    }

    #[test]
    fun test_iterator() {
        let tree = new_with_order(5);

        let data = vector[1, 7, 5, 8, 4, 2, 6, 3, 9, 0];
        while (vector::length(&data) != 0) {
            let element = vector::pop_back(&mut data);
            insert(&mut tree, element, element);
        };

        let it = new_begin_iter(&tree);

        let i = 0;
        while (!is_end_iter(&tree, &it)) {
            assert!(i == it.key, E_UNKNOWN);
            i = i + 1;
            it = option::extract(&mut next_iter(&tree, it));
        };

        destroy(tree);
    }

    #[test]
    fun test_find() {
        let tree = new_with_order(5);

        let data = vector[11, 1, 7, 5, 8, 2, 6, 3, 0, 10];

        let i = 0;
        let len = vector::length(&data);
        while (i < len) {
            let element = *vector::borrow(&data, i);
            insert(&mut tree, element, element);
            i = i + 1;
        };

        let i = 0;
        while (i < len) {
            let element = *vector::borrow(&data, i);
            let it = find(&tree, element);
            assert!(!is_end_iter(&tree, &it), E_UNKNOWN);
            assert!(it.key == element, E_UNKNOWN);
            i = i + 1;
        };

        assert!(is_end_iter(&tree, &find(&tree, 4)), E_UNKNOWN);
        assert!(is_end_iter(&tree, &find(&tree, 9)), E_UNKNOWN);

        destroy(tree);
    }

    #[test]
    fun test_lower_bound() {
        let tree = new_with_order(5);

        let data = vector[11, 1, 7, 5, 8, 2, 6, 3, 12, 10];

        let i = 0;
        let len = vector::length(&data);
        while (i < len) {
            let element = *vector::borrow(&data, i);
            insert(&mut tree, element, element);
            i = i + 1;
        };

        let i = 0;
        while (i < len) {
            let element = *vector::borrow(&data, i);
            let it = lower_bound(&tree, element);
            assert!(!is_end_iter(&tree, &it), E_UNKNOWN);
            assert!(it.key == element, E_UNKNOWN);
            i = i + 1;
        };

        assert!(lower_bound(&tree, 0).key == 1, E_UNKNOWN);
        assert!(lower_bound(&tree, 4).key == 5, E_UNKNOWN);
        assert!(lower_bound(&tree, 9).key == 10, E_UNKNOWN);
        assert!(is_end_iter(&tree, &lower_bound(&tree, 13)), E_UNKNOWN);

        remove(&mut tree, 3);
        assert!(lower_bound(&tree, 3).key == 5, E_UNKNOWN);
        remove(&mut tree, 5);
        assert!(lower_bound(&tree, 3).key == 6, E_UNKNOWN);
        assert!(lower_bound(&tree, 4).key == 6, E_UNKNOWN);

        destroy(tree);
    }

    #[test]
    fun test_large_data_set() {
        let tree = new_with_order(5);
        let data = vector[47966, 12695, 38329, 37122, 29979, 51895, 59614, 26820, 28665, 46241, 59409, 15817, 47595, 9600, 23091, 17535, 64010, 20825, 49063, 421, 45346, 25734, 29005, 39025, 20821, 13464, 24935, 13942, 55667, 43034, 14456, 38098, 55730, 52785, 9684, 20173, 39145, 3762, 46993, 2274, 50003, 40866, 18091, 32062, 50467, 41182, 49598, 48941, 62008, 33125, 49363, 41818, 58859, 12832, 15307, 14145, 26296, 40243, 28087, 16428, 17741, 42543, 54526, 7935, 29792, 64210, 28108, 3401, 2436, 9565, 5675, 52439, 50432, 23766, 18966, 35363, 64949, 3028, 18768, 61421, 36153, 2595, 37703, 29477, 15428, 53010, 43622, 41724, 27717, 6173, 58152, 45459, 48716, 47142, 53394, 12972, 45816, 15967, 16374, 48252, 25532, 22049, 35156, 10428, 45816, 54122, 45791, 45229, 57150, 64560, 41114, 27767, 1619, 13281, 57244, 17047, 755, 35330, 58772, 28473, 41503, 51388, 8396, 24683, 32995, 61790, 37656, 13275, 12221, 54030, 61528, 37754, 10543, 31148, 48182, 56359, 19734, 28438, 36052, 11348, 27462, 11630, 39115, 29081, 24911, 30824, 46129, 25667, 618, 39365, 54140, 42122, 25217, 62536, 1269, 58212, 58790, 38925, 5952, 5476, 27419, 1944, 43230, 37963, 33092, 25876, 28786, 52826, 54314, 64839, 64174, 16240, 10933, 37753, 45322, 35845, 3041, 25915, 61512, 3660, 65280, 50116, 45782, 24961, 47116, 47051, 17638, 40370, 20441, 23590, 45846, 47860, 25534, 23540, 20287, 58626, 49417, 49074, 45916, 38195, 48377, 44554, 54436, 59310, 16771, 34222, 29619, 19813, 60137, 25595, 23473, 59881, 10175, 3719, 19306, 57291, 50770, 36944, 32126, 5675, 60534, 12436, 53536, 20532, 35977, 8287, 13622, 19858, 57361, 59538, 58053, 40202, 38556, 46953, 33977, 55328, 15639, 63596, 9605, 10240, 23656, 33078, 4585, 33831, 36797, 23892, 25587, 22031, 60836, 57713, 27707, 55835, 4613, 15707, 10831, 40590, 23994, 24454, 60448, 15820, 18456, 52966, 56022, 57013, 34383, 24463, 46805, 50023, 22524, 56410, 60263, 46180, 23952, 64849, 14475, 60749, 23205, 40062, 17244, 18505, 32239, 44951, 8804, 36853, 60658, 19636, 11907, 19117, 44090, 6820, 34937, 62546, 59786, 25423, 54023, 28633, 49887, 35292, 13120, 6875, 26166, 7848, 53055, 50118, 7161, 1994, 45331, 30366, 42057, 62576, 48871, 8760, 41991, 57676, 45613, 37114, 11776, 57521, 56231, 55866, 64341, 25632, 52876, 58591, 51055, 41364, 21688, 35406, 11120, 34809, 42281, 37287, 42657, 29800, 21869, 49818, 31795, 1665, 14648, 8316, 64241, 63519, 17076, 40696, 55659, 62690, 12274, 1899, 54675, 2969, 57765, 53480, 28601, 45106, 46535, 14121, 20934, 2687, 49527, 32054, 37496, 26273, 3805, 14617, 56073, 25675, 64435, 22332, 27340, 13547, 30648, 26045, 11531, 47725, 1205, 1654, 44879, 13480, 3554, 34018, 16449, 61319, 21962, 45051, 40889, 2961, 59172, 61823, 5648, 43163, 28342, 43145, 3900, 32147, 57762, 59974, 57822, 56662, 16770, 19626, 4673, 47419, 45671, 16204, 29608, 46877, 17859, 8951, 60357, 21413, 42969, 11270, 17196, 64931, 56321, 58086, 2356, 49957, 54373, 8004, 27585, 17179, 51149, 31485, 49327, 43376, 25923, 41613, 34502, 42694, 61240, 39175, 24577, 41375, 55380, 54185, 22716, 7703, 63136, 17537, 29116, 40569, 28808, 46312, 39964, 19593, 38862, 42320, 4015, 27700, 50324, 31600, 44879, 35938, 63085, 28670, 13778, 23473, 4748, 48280, 631, 452, 21919, 25208, 41827, 11763, 13857, 64544, 19466, 11457, 16545, 48582, 52026, 45353, 29359, 26454, 64947, 2685, 3238, 3426, 30385, 53562, 35026, 9729, 23964, 32575, 38399, 37742, 56048, 43147, 20486, 56679, 43599, 42406, 16351, 19891, 54169, 30208, 18899, 8100, 41665, 35444, 56682, 28155, 15262, 20505, 54609, 14673, 23191, 57847, 18099, 53576, 45874, 53125, 63305, 4302, 20164, 36169, 42045, 10677, 13780, 62531, 1820, 57380, 39401, 18172, 11735, 28035, 48380, 30634, 36135, 24510, 542, 27281, 52665, 15804, 47787, 41739, 30477, 5442, 34050, 48576, 59018, 14388, 36165, 56788, 18691, 56330, 27421, 60736, 1471, 41201, 57731, 3291, 33045, 31597, 21463, 44780, 59632, 4308, 9878, 30231, 28818, 10421, 57512, 15947, 26225, 39763, 57686, 56703, 45205, 26201, 39743, 38688, 40589, 10373, 29940, 59280, 1167, 57361, 54480, 2638, 33026, 46676, 5929, 536, 12737, 27393, 45316, 6833, 31701, 55195, 37064, 60519, 80, 29040, 10930, 26305, 3268, 3081, 17472, 48473, 29282, 57216, 21625, 4335, 2053, 51565, 63616, 3220, 43390, 52560, 5858, 10881, 33700, 11787, 11417, 46437, 39180, 56733, 53270, 5345, 46392, 24798, 328, 46472, 53839, 11259, 7242, 57107, 14340, 24714, 40044, 43622, 16394, 61670, 47957, 18447, 47699, 46037, 21667, 25554, 33062, 27525, 36435, 1226, 39313, 47852, 47664, 12957];
        let shuffled_data = vector[57713, 43163, 58790, 57107, 43599, 47957, 9684, 50118, 27281, 46993, 3554, 26045, 44879, 49074, 3220, 34383, 62576, 64341, 45791, 1471, 59881, 12695, 53270, 32995, 3805, 55659, 47142, 29792, 1226, 46535, 11531, 57822, 16449, 23091, 33078, 5952, 25554, 536, 41375, 46037, 56733, 30824, 5858, 34050, 27462, 53010, 46312, 61670, 45316, 11259, 33977, 10428, 10930, 25595, 57361, 11630, 38329, 41827, 55380, 19734, 12737, 18091, 57013, 1205, 49417, 29040, 56073, 3660, 20287, 29477, 42281, 23892, 45816, 63519, 15947, 2961, 49818, 58212, 50432, 62536, 47051, 48473, 25675, 15967, 45846, 45322, 14648, 23994, 64931, 33700, 38195, 28808, 3719, 42406, 1820, 51895, 48380, 14475, 45353, 328, 57244, 39964, 24961, 32575, 30477, 31600, 13464, 8804, 35292, 54436, 22716, 47699, 21625, 53055, 39145, 23473, 46241, 49887, 3081, 20934, 1944, 43622, 27393, 13778, 30385, 80, 19891, 28818, 41739, 58152, 62690, 18899, 10240, 15707, 30648, 33831, 28473, 6820, 29359, 29005, 1899, 24714, 47860, 39401, 43376, 55328, 1619, 57686, 59614, 20825, 36797, 54023, 62531, 34809, 48576, 27525, 38399, 47116, 36169, 23590, 28108, 45229, 6833, 13942, 45346, 32126, 29282, 57291, 35977, 56231, 64849, 41991, 12436, 59280, 25423, 32054, 7242, 14340, 55835, 3291, 42969, 42057, 10175, 9605, 29800, 35938, 48252, 13780, 57216, 60448, 56703, 43622, 63596, 5345, 20532, 52560, 28670, 40370, 48941, 57762, 25632, 61790, 16770, 43145, 42045, 55195, 49363, 43390, 37496, 46953, 37742, 24454, 65280, 39763, 25534, 44780, 63136, 35845, 38862, 18099, 25876, 64010, 53394, 54122, 17638, 21463, 19626, 61823, 55667, 15428, 26166, 5675, 28035, 33125, 10831, 20486, 53576, 59310, 57361, 46180, 39115, 52026, 60534, 17535, 12221, 13857, 40590, 39743, 26201, 41818, 49063, 20821, 48377, 28601, 52785, 15820, 11763, 4335, 8760, 47852, 60137, 27767, 54526, 26225, 57380, 25217, 49327, 54030, 15307, 49527, 63616, 1269, 7703, 64560, 2356, 26273, 56321, 45874, 46472, 4673, 9729, 18447, 11348, 45459, 48182, 40696, 40589, 21413, 59632, 11735, 59786, 17179, 14673, 7161, 47419, 14145, 27717, 44090, 57512, 37753, 45205, 3041, 19466, 17244, 40062, 5442, 2595, 1654, 31597, 42694, 24683, 23964, 45816, 12957, 23540, 56682, 42320, 2685, 35330, 53839, 58591, 57765, 54314, 33045, 64241, 35156, 39313, 60357, 41201, 22031, 64947, 52665, 59538, 11907, 18456, 27707, 8004, 11787, 631, 452, 63305, 37287, 61319, 55866, 64174, 39180, 35406, 45671, 30366, 5929, 58086, 36165, 46437, 25587, 64435, 10933, 1167, 25923, 64839, 41364, 28438, 25734, 61528, 22524, 23205, 34937, 37122, 58772, 23766, 33026, 4748, 56410, 19858, 19813, 56788, 10677, 57150, 41114, 57847, 56679, 27419, 46805, 51149, 21869, 20505, 13622, 54480, 51055, 27340, 17076, 56022, 46392, 16374, 52439, 6875, 29116, 24798, 29081, 23473, 30231, 23191, 53536, 31148, 31795, 46877, 32147, 62008, 36944, 47966, 37703, 40889, 59974, 57521, 7848, 13275, 50467, 2638, 24935, 48716, 36435, 24577, 24463, 1994, 56048, 8100, 16240, 8287, 27700, 37754, 38098, 421, 37963, 26454, 21688, 19593, 21919, 4302, 41613, 44879, 31485, 60749, 26305, 15639, 64949, 29608, 4613, 35026, 20164, 28665, 2969, 60519, 8316, 43230, 36153, 20441, 6173, 25532, 11120, 618, 34018, 36853, 11457, 17047, 50770, 56662, 14617, 15804, 25208, 25915, 36135, 35444, 34222, 542, 29619, 10373, 33092, 3268, 16204, 21962, 54169, 54373, 61240, 10543, 19636, 43034, 16351, 47595, 46129, 20173, 37656, 2687, 17537, 59172, 17196, 53125, 60263, 3401, 19306, 27421, 34502, 4015, 11776, 41724, 42657, 54140, 42543, 36052, 30634, 25667, 12274, 17741, 18505, 8951, 10881, 31701, 11270, 54609, 28633, 42122, 18768, 23952, 38556, 18966, 30208, 53480, 45916, 7935, 14456, 3028, 61512, 24510, 16771, 29979, 35363, 61421, 41182, 64210, 55730, 29940, 12832, 49598, 2053, 13281, 58053, 38925, 9600, 50003, 39175, 12972, 2274, 15817, 40569, 18691, 52966, 18172, 48871, 14388, 39365, 45613, 28155, 60658, 17859, 57676, 13120, 60836, 16545, 37114, 40243, 19117, 32062, 41503, 3238, 56330, 28786, 50324, 44554, 45051, 53562, 59018, 57731, 14121, 28342, 4585, 13480, 50023, 40044, 51565, 22332, 44951, 9565, 2436, 45782, 52826, 3762, 40866, 60736, 59409, 28087, 48280, 32239, 16394, 5476, 40202, 9878, 33062, 58859, 21667, 41665, 48582, 54185, 755, 5675, 10421, 5648, 45106, 22049, 37064, 52876, 27585, 50116, 47725, 8396, 38688, 43147, 54675, 17472, 47664, 47787, 15262, 11417, 62546, 13547, 3426, 26820, 39025, 24911, 58626, 3900, 23656, 45331, 46676, 1665, 56359, 51388, 63085, 4308, 26296, 16428, 49957, 64544];

        let i = 0;
        let len = vector::length(&data);
        while (i < len) {
            let element = *vector::borrow(&data, i);
            upsert(&mut tree, element, element);
            validate_tree(&tree);
            i = i + 1;
        };

        let i = 0;
        while (i < len) {
            let element = *vector::borrow(&shuffled_data, i);
            let it = find(&tree, element);
            assert!(!is_end_iter(&tree, &it), E_UNKNOWN);
            assert!(it.key == element, E_UNKNOWN);
            i = i + 1;
        };

        destroy(tree);
    }
}
