This module provides an GRPC endpoint to Aptos fullnode used for indexing purposes. 

## Overview

### Models

Models or types are defined in the `aptos-api-types` package (in the directory `/api/types`).

These types handle deserialization between internal data types and API response JSON types. These are then used to
construct the Protobuf messages.

### Error Handling

All internal errors should be converted into `anyhow::Error` first.

### Unit Test

Handler tests should cover all aspects of features and functions.

A `TestContext` is implemented to create components' stubs that API handlers are connected to.
These stubs are more close to real production components, instead of mocks, so that tests can ensure the handlers are
working well with other components in the systems.
For example, we use real AptosDB implementation in tests for API layers to interact with the database.

Most of the utility functions are provided by the `TestContext`.

### Integration/Smoke Test

TBD

## Aptos Node Operation

TBD

## Installing Protobuf Compiler

TBD

## Run Locally

TBD