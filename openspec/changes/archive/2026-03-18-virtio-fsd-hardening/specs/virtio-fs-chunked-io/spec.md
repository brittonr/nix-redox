## ADDED Requirements

### Requirement: Reads exceeding max_read are chunked
When a `read` call requests more bytes than the FUSE-negotiated `max_write` (which also governs max read size), the `FuseSession` SHALL split the request into multiple FUSE_READ operations, each at most `max_write` bytes, and concatenate the results.

#### Scenario: Read a 2 MiB region with 1 MiB max
- **WHEN** a caller reads 2 MiB from offset 0 and `max_write` is 1 MiB
- **THEN** the session sends two FUSE_READ requests (offset 0 size 1M, offset 1M size 1M) and returns the combined 2 MiB result

#### Scenario: Short read terminates chunking early
- **WHEN** a chunked read receives fewer bytes than requested in a chunk (short read, e.g., EOF)
- **THEN** the session stops issuing further chunks and returns the data accumulated so far

#### Scenario: Read within max_write is not chunked
- **WHEN** a caller reads 512 KiB and `max_write` is 1 MiB
- **THEN** the session sends a single FUSE_READ (no chunking overhead)

### Requirement: Writes exceeding max_write are chunked
When a `write` call provides more data than the FUSE-negotiated `max_write`, the `FuseSession` SHALL split the data into multiple FUSE_WRITE operations, each at most `max_write` bytes, advancing the offset for each chunk.

#### Scenario: Write a 3 MiB buffer with 1 MiB max
- **WHEN** a caller writes 3 MiB at offset 0 and `max_write` is 1 MiB
- **THEN** the session sends three FUSE_WRITE requests (offset 0, 1M, 2M) and returns total bytes written (3 MiB)

#### Scenario: Short write terminates chunking with partial count
- **WHEN** the host writes fewer bytes than the chunk size for a FUSE_WRITE
- **THEN** the session stops issuing further chunks and returns the total bytes written so far

#### Scenario: Write within max_write is not chunked
- **WHEN** a caller writes 256 KiB and `max_write` is 1 MiB
- **THEN** the session sends a single FUSE_WRITE (no chunking overhead)

### Requirement: Chunking respects DMA buffer limits
Chunk sizes SHALL NOT exceed `MAX_IO_SIZE` (the pre-allocated DMA buffer capacity), even if the host negotiates a larger `max_write`. The effective chunk size is `min(max_write, MAX_IO_SIZE)`.

#### Scenario: Host negotiates max_write larger than DMA buffer
- **WHEN** the host negotiates `max_write` of 2 MiB but `MAX_IO_SIZE` is 1 MiB
- **THEN** chunks are capped at 1 MiB to fit the pre-allocated DMA buffer
