# Changelog

All notable changes to this project will be documented in this file.

## [1.1.7] - 2026-07-28

### Fixed
- Generated puzzles had no uniqueness verification at all — measured as
  low as 1 in 10 puzzles actually having a unique solution at the
  hardest size/difficulty. Added a uniqueness solver and reworked
  generation to verify each puzzle before accepting it. Every puzzle now
  ships with a guaranteed unique solution.
