# RFC-0008 Odin Style Guide

## Rules
- Explicit allocators
- No per-row allocations
- Column-oriented layout
- Avoid maps in hot loops
- Vectorized execution

## Data Layout
Prefer Structure-of-Arrays (SoA).
