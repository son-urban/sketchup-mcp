# AGENTS.md - SketchUp MCP

## Project Overview

Two-component system connecting Claude AI to SketchUp via Model Context Protocol (MCP):
1. **Python MCP Server** (`src/sketchup_mcp/`): FastMCP-based server exposing tools to Claude
2. **SketchUp Ruby Extension** (`su_mcp/`): TCP server inside SketchUp that executes Ruby commands

Communication: JSON-RPC 2.0 over TCP socket on port 9876.

## Quick Start

```bash
# Install Python package (uses uv)
brew install uv
uv pip install -e .

# Run MCP server
python -m sketchup_mcp

# Package Ruby extension for distribution
ruby su_mcp/package.rb  # Creates su_mcp_v1.6.0.rbz
```

**To use with SketchUp:**
1. Install the `.rbz` via SketchUp > Extension Manager
2. In SketchUp: Extensions > SketchupMCP > Start Server
3. Configure Claude with the MCP server settings from `sketchup.json`

## Key File Locations

| Purpose | Path |
|---------|------|
| MCP server entrypoint | `src/sketchup_mcp/server.py` |
| Ruby extension entrypoint | `su_mcp/su_mcp.rb` |
| Ruby extension main logic | `su_mcp/su_mcp/main.rb` |
| Extension packaging script | `su_mcp/package.rb` |
| MCP manifest/config | `sketchup.json` |
| Example scripts | `examples/` |

## Architecture Notes

**MCP Tools → TCP Commands:**
- Python MCP tools (`create_component`, `eval_ruby`, etc.) serialize to JSON-RPC
- Ruby extension receives on port 9876, executes via SketchUp Ruby API
- Version must match: Python `__version__` = `0.1.17`, Ruby extension = `1.6.0`

**Critical Connection Requirements:**
- SketchUp extension must be started BEFORE MCP server connects
- Extension runs TCP server on `127.0.0.1:9876`
- MCP server auto-reconnects with 2 retries on connection failure

## Development Commands

```bash
# Run test script (requires SketchUp running with extension)
python test_eval_ruby.py

# Run example scripts
python examples/simple_ruby_eval.py
python examples/arts_and_crafts_cabinet.py

# Package extension for release
ruby su_mcp/package.rb
```

## Build & Release

**Update version in 3 places:**
1. `pyproject.toml` (project.version)
2. `src/sketchup_mcp/__init__.py` (`__version__`)
3. `src/sketchup_mcp/server.py` (`__version__`)
4. `su_mcp/extension.json` (version)
5. `su_mcp/package.rb` (VERSION constant)
6. `su_mcp/su_mcp.rb` (ext.version)

**PyPI release:**
```bash
python -m build
twine upload dist/*
```

**Users install via:** `uvx sketchup-mcp` (pulls from PyPI)

## Testing

- `test_eval_ruby.py`: Quick validation of `eval_ruby` tool
- `examples/simple_ruby_eval.py`: Basic Ruby code execution tests
- `examples/behavior_tester.py`: Component behavior testing
- `examples/ruby_tester.py`: Ruby API integration tests

No automated test runner—tests require SketchUp to be running with the extension active.

## Code Conventions

- Python: Uses `mcp[cli]>=1.3.0`, FastMCP pattern with `@mcp.tool()` decorators
- Ruby: Extension follows SketchUp `SketchupExtension` pattern
- Line endings in Ruby: SketchUp console prefers explicit `\n` for logging

## Common Pitfalls

1. **Version mismatch** between Python package and Ruby extension causes protocol errors
2. **SketchUp must be running** with extension server started before MCP tools work
3. **TCP port 9876** is hardcoded in both Python and Ruby—cannot change without editing both
4. **SketchUp API stubs** in `lib/sketchup-api-stubs/` are for development reference only

## Dependencies

**Python:** `mcp[cli]>=1.3.0`, `websockets>=12.0`, `aiohttp>=3.9.0`
**Ruby (for packaging):** `rubyzip` gem
**Runtime:** SketchUp with Ruby console support
