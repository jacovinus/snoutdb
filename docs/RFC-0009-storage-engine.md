# RFC-0009 Storage Engine

## Storage Model
Columnar chunks.

## Statistics
Per chunk:
- row count
- null count
- min
- max
- compressed size

## Compression
- Dictionary encoding
- Delta encoding
- RLE
