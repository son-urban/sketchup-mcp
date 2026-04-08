from mcp.server.fastmcp import FastMCP, Context
import socket
import json
import asyncio
import logging
from dataclasses import dataclass
from contextlib import asynccontextmanager
from typing import AsyncIterator, Dict, Any, List

# Configure logging
logging.basicConfig(
    level=logging.INFO, format="%(asctime)s - %(name)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger("SketchupMCPServer")

# Define version directly to avoid pkg_resources dependency
__version__ = "0.1.17"
logger.info(f"SketchupMCP Server version {__version__} starting up")


@dataclass
class SketchupConnection:
    host: str
    port: int
    sock: socket.socket = None

    def connect(self) -> bool:
        """Connect to the Sketchup extension socket server"""
        if self.sock:
            try:
                # Test if connection is still alive
                self.sock.settimeout(0.1)
                self.sock.send(b"")
                return True
            except (socket.error, BrokenPipeError, ConnectionResetError):
                # Connection is dead, close it and reconnect
                logger.info("Connection test failed, reconnecting...")
                self.disconnect()

        try:
            self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            self.sock.connect((self.host, self.port))
            logger.info(f"Connected to Sketchup at {self.host}:{self.port}")
            return True
        except Exception as e:
            logger.error(f"Failed to connect to Sketchup: {str(e)}")
            self.sock = None
            return False

    def disconnect(self):
        """Disconnect from the Sketchup extension"""
        if self.sock:
            try:
                self.sock.close()
            except Exception as e:
                logger.error(f"Error disconnecting from Sketchup: {str(e)}")
            finally:
                self.sock = None

    def receive_full_response(self, sock, buffer_size=8192):
        """Receive the complete response, potentially in multiple chunks"""
        chunks = []
        sock.settimeout(15.0)

        try:
            while True:
                try:
                    chunk = sock.recv(buffer_size)
                    if not chunk:
                        if not chunks:
                            raise Exception(
                                "Connection closed before receiving any data"
                            )
                        break

                    chunks.append(chunk)

                    try:
                        data = b"".join(chunks)
                        json.loads(data.decode("utf-8"))
                        logger.info(f"Received complete response ({len(data)} bytes)")
                        return data
                    except json.JSONDecodeError:
                        continue
                except socket.timeout:
                    logger.warning("Socket timeout during chunked receive")
                    break
                except (ConnectionError, BrokenPipeError, ConnectionResetError) as e:
                    logger.error(f"Socket connection error during receive: {str(e)}")
                    raise
        except socket.timeout:
            logger.warning("Socket timeout during chunked receive")
        except Exception as e:
            logger.error(f"Error during receive: {str(e)}")
            raise

        if chunks:
            data = b"".join(chunks)
            logger.info(f"Returning data after receive completion ({len(data)} bytes)")
            try:
                json.loads(data.decode("utf-8"))
                return data
            except json.JSONDecodeError:
                raise Exception("Incomplete JSON response received")
        else:
            raise Exception("No data received")

    def send_command(
        self, method: str, params: Dict[str, Any] = None, request_id: Any = None
    ) -> Dict[str, Any]:
        """Send a JSON-RPC request to Sketchup and return the response"""
        # Try to connect if not connected
        if not self.connect():
            raise ConnectionError("Not connected to Sketchup")

        # Ensure we're sending a proper JSON-RPC request
        if (
            method == "tools/call"
            and params
            and "name" in params
            and "arguments" in params
        ):
            # This is already in the correct format
            request = {
                "jsonrpc": "2.0",
                "method": method,
                "params": params,
                "id": request_id,
            }
        else:
            # This is a direct command - convert to JSON-RPC
            command_name = method
            command_params = params or {}

            # Log the conversion
            logger.info(
                f"Converting direct command '{command_name}' to JSON-RPC format"
            )

            request = {
                "jsonrpc": "2.0",
                "method": "tools/call",
                "params": {"name": command_name, "arguments": command_params},
                "id": request_id,
            }

        # Maximum number of retries
        max_retries = 2
        retry_count = 0

        while retry_count <= max_retries:
            try:
                logger.info(f"Sending JSON-RPC request: {request}")

                # Log the exact bytes being sent
                request_bytes = json.dumps(request).encode("utf-8") + b"\n"
                logger.info(f"Raw bytes being sent: {request_bytes}")

                self.sock.sendall(request_bytes)
                logger.info(f"Request sent, waiting for response...")

                self.sock.settimeout(15.0)

                response_data = self.receive_full_response(self.sock)
                logger.info(f"Received {len(response_data)} bytes of data")

                response = json.loads(response_data.decode("utf-8"))
                logger.info(f"Response parsed: {response}")

                if "error" in response:
                    logger.error(f"Sketchup error: {response['error']}")
                    raise Exception(
                        response["error"].get("message", "Unknown error from Sketchup")
                    )

                return response.get("result", {})

            except (
                socket.timeout,
                ConnectionError,
                BrokenPipeError,
                ConnectionResetError,
            ) as e:
                logger.warning(
                    f"Connection error (attempt {retry_count + 1}/{max_retries + 1}): {str(e)}"
                )
                retry_count += 1

                if retry_count <= max_retries:
                    logger.info(f"Retrying connection...")
                    self.disconnect()
                    if not self.connect():
                        logger.error("Failed to reconnect")
                        break
                else:
                    logger.error(f"Max retries reached, giving up")
                    self.sock = None
                    raise Exception(
                        f"Connection to Sketchup lost after {max_retries + 1} attempts: {str(e)}"
                    )

            except json.JSONDecodeError as e:
                logger.error(f"Invalid JSON response from Sketchup: {str(e)}")
                if "response_data" in locals() and response_data:
                    logger.error(
                        f"Raw response (first 200 bytes): {response_data[:200]}"
                    )
                raise Exception(f"Invalid response from Sketchup: {str(e)}")

            except Exception as e:
                logger.error(f"Error communicating with Sketchup: {str(e)}")
                self.sock = None
                raise Exception(f"Communication error with Sketchup: {str(e)}")


# Global connection management
_sketchup_connection = None


def get_sketchup_connection():
    """Get or create a persistent Sketchup connection"""
    global _sketchup_connection

    if _sketchup_connection is not None:
        try:
            # Test connection with a ping command
            ping_request = {"jsonrpc": "2.0", "method": "ping", "params": {}, "id": 0}
            _sketchup_connection.sock.sendall(
                json.dumps(ping_request).encode("utf-8") + b"\n"
            )
            return _sketchup_connection
        except Exception as e:
            logger.warning(f"Existing connection is no longer valid: {str(e)}")
            try:
                _sketchup_connection.disconnect()
            except:
                pass
            _sketchup_connection = None

    if _sketchup_connection is None:
        _sketchup_connection = SketchupConnection(host="localhost", port=9876)
        if not _sketchup_connection.connect():
            logger.error("Failed to connect to Sketchup")
            _sketchup_connection = None
            raise Exception(
                "Could not connect to Sketchup. Make sure the Sketchup extension is running."
            )
        logger.info("Created new persistent connection to Sketchup")

    return _sketchup_connection


@asynccontextmanager
async def server_lifespan(server: FastMCP) -> AsyncIterator[Dict[str, Any]]:
    """Manage server startup and shutdown lifecycle"""
    try:
        logger.info("SketchupMCP server starting up")
        try:
            sketchup = get_sketchup_connection()
            logger.info("Successfully connected to Sketchup on startup")
        except Exception as e:
            logger.warning(f"Could not connect to Sketchup on startup: {str(e)}")
            logger.warning("Make sure the Sketchup extension is running")
        yield {}
    finally:
        global _sketchup_connection
        if _sketchup_connection:
            logger.info("Disconnecting from Sketchup")
            _sketchup_connection.disconnect()
            _sketchup_connection = None
        logger.info("SketchupMCP server shut down")


# Create MCP server with lifespan support
mcp = FastMCP(
    "SketchupMCP",
    lifespan=server_lifespan,
)


# Tool endpoints
@mcp.tool()
def create_component(
    ctx: Context,
    type: str = "cube",
    position: List[float] = None,
    dimensions: List[float] = None,
) -> str:
    """Create a new component in Sketchup"""
    try:
        logger.info(
            f"create_component called with type={type}, position={position}, dimensions={dimensions}, request_id={ctx.request_id}"
        )

        sketchup = get_sketchup_connection()

        params = {
            "name": "create_component",
            "arguments": {
                "type": type,
                "position": position or [0, 0, 0],
                "dimensions": dimensions or [1, 1, 1],
            },
        }

        logger.info(
            f"Calling send_command with method='tools/call', params={params}, request_id={ctx.request_id}"
        )

        result = sketchup.send_command(
            method="tools/call", params=params, request_id=ctx.request_id
        )

        logger.info(f"create_component result: {result}")
        return json.dumps(result)
    except Exception as e:
        logger.error(f"Error in create_component: {str(e)}")
        return f"Error creating component: {str(e)}"


@mcp.tool()
def delete_component(ctx: Context, id: str) -> str:
    """Delete a component by ID"""
    try:
        sketchup = get_sketchup_connection()
        result = sketchup.send_command(
            method="tools/call",
            params={"name": "delete_component", "arguments": {"id": id}},
            request_id=ctx.request_id,
        )
        return json.dumps(result)
    except Exception as e:
        return f"Error deleting component: {str(e)}"


@mcp.tool()
def transform_component(
    ctx: Context,
    id: str,
    position: List[float] = None,
    rotation: List[float] = None,
    scale: List[float] = None,
) -> str:
    """Transform a component's position, rotation, or scale"""
    try:
        sketchup = get_sketchup_connection()
        arguments = {"id": id}
        if position is not None:
            arguments["position"] = position
        if rotation is not None:
            arguments["rotation"] = rotation
        if scale is not None:
            arguments["scale"] = scale

        result = sketchup.send_command(
            method="tools/call",
            params={"name": "transform_component", "arguments": arguments},
            request_id=ctx.request_id,
        )
        return json.dumps(result)
    except Exception as e:
        return f"Error transforming component: {str(e)}"


@mcp.tool()
def get_selection(ctx: Context) -> str:
    """Get currently selected components"""
    try:
        sketchup = get_sketchup_connection()
        result = sketchup.send_command(
            method="tools/call",
            params={"name": "get_selection", "arguments": {}},
            request_id=ctx.request_id,
        )
        return json.dumps(result)
    except Exception as e:
        return f"Error getting selection: {str(e)}"


@mcp.tool()
def set_material(ctx: Context, id: str, material: str) -> str:
    """Set material for a component"""
    try:
        sketchup = get_sketchup_connection()
        result = sketchup.send_command(
            method="tools/call",
            params={
                "name": "set_material",
                "arguments": {"id": id, "material": material},
            },
            request_id=ctx.request_id,
        )
        return json.dumps(result)
    except Exception as e:
        return f"Error setting material: {str(e)}"


# =============================================================================
# Operation Management Tools
# =============================================================================

@mcp.tool()
def start_operation(ctx: Context, name: str, transparent: bool = False) -> str:
    """Start a new undoable operation in SketchUp.

    This allows multiple operations to be grouped together as a single undo step.
    Must be paired with either commit_operation or abort_operation.

    Args:
        name: Name of the operation (shown in Edit menu)
        transparent: If True, operation won't create separate undo step
    """
    try:
        logger.info(f"start_operation called with name={name}, transparent={transparent}")

        sketchup = get_sketchup_connection()

        result = sketchup.send_command(
            method="tools/call",
            params={
                "name": "start_operation",
                "arguments": {"name": name, "transparent": transparent},
            },
            request_id=ctx.request_id,
        )

        logger.info(f"start_operation result: {result}")
        return json.dumps(result)
    except Exception as e:
        logger.error(f"Error in start_operation: {str(e)}")
        return json.dumps({"success": False, "error": str(e)})


@mcp.tool()
def commit_operation(ctx: Context) -> str:
    """Commit the current operation to the undo stack.

    This finalizes the operation started with start_operation.
    All changes made since start_operation will be grouped as one undo step.
    """
    try:
        logger.info("commit_operation called")

        sketchup = get_sketchup_connection()

        result = sketchup.send_command(
            method="tools/call",
            params={"name": "commit_operation", "arguments": {}},
            request_id=ctx.request_id,
        )

        logger.info(f"commit_operation result: {result}")
        return json.dumps(result)
    except Exception as e:
        logger.error(f"Error in commit_operation: {str(e)}")
        return json.dumps({"success": False, "error": str(e)})


@mcp.tool()
def abort_operation(ctx: Context) -> str:
    """Abort the current operation, reverting all changes.

    This cancels the operation started with start_operation and reverts
    the model to its state before the operation began.
    """
    try:
        logger.info("abort_operation called")

        sketchup = get_sketchup_connection()

        result = sketchup.send_command(
            method="tools/call",
            params={"name": "abort_operation", "arguments": {}},
            request_id=ctx.request_id,
        )

        logger.info(f"abort_operation result: {result}")
        return json.dumps(result)
    except Exception as e:
        logger.error(f"Error in abort_operation: {str(e)}")
        return json.dumps({"success": False, "error": str(e)})


@mcp.tool()
def undo(ctx: Context, count: int = 1) -> str:
    """Undo the last operation(s) in SketchUp.

    Args:
        count: Number of operations to undo (default: 1)
    """
    try:
        logger.info(f"undo called with count={count}")

        sketchup = get_sketchup_connection()

        result = sketchup.send_command(
            method="tools/call",
            params={"name": "undo", "arguments": {"count": count}},
            request_id=ctx.request_id,
        )

        logger.info(f"undo result: {result}")
        return json.dumps(result)
    except Exception as e:
        logger.error(f"Error in undo: {str(e)}")
        return json.dumps({"success": False, "error": str(e)})


@mcp.tool()
def redo(ctx: Context, count: int = 1) -> str:
    """Redo previously undone operation(s) in SketchUp.

    Args:
        count: Number of operations to redo (default: 1)
    """
    try:
        logger.info(f"redo called with count={count}")

        sketchup = get_sketchup_connection()

        result = sketchup.send_command(
            method="tools/call",
            params={"name": "redo", "arguments": {"count": count}},
            request_id=ctx.request_id,
        )

        logger.info(f"redo result: {result}")
        return json.dumps(result)
    except Exception as e:
        logger.error(f"Error in redo: {str(e)}")
        return json.dumps({"success": False, "error": str(e)})


@mcp.tool()
def export_scene(ctx: Context, format: str = "skp") -> str:
    """Export the current scene"""
    try:
        sketchup = get_sketchup_connection()
        result = sketchup.send_command(
            method="tools/call",
            params={"name": "export", "arguments": {"format": format}},
            request_id=ctx.request_id,
        )
        return json.dumps(result)
    except Exception as e:
        return f"Error exporting scene: {str(e)}"


@mcp.tool()
def create_mortise_tenon(
    ctx: Context,
    mortise_id: str,
    tenon_id: str,
    width: float = 1.0,
    height: float = 1.0,
    depth: float = 1.0,
    offset_x: float = 0.0,
    offset_y: float = 0.0,
    offset_z: float = 0.0,
) -> str:
    """Create a mortise and tenon joint between two components"""
    try:
        logger.info(
            f"create_mortise_tenon called with mortise_id={mortise_id}, tenon_id={tenon_id}, width={width}, height={height}, depth={depth}, offsets=({offset_x}, {offset_y}, {offset_z})"
        )

        sketchup = get_sketchup_connection()

        result = sketchup.send_command(
            method="tools/call",
            params={
                "name": "create_mortise_tenon",
                "arguments": {
                    "mortise_id": mortise_id,
                    "tenon_id": tenon_id,
                    "width": width,
                    "height": height,
                    "depth": depth,
                    "offset_x": offset_x,
                    "offset_y": offset_y,
                    "offset_z": offset_z,
                },
            },
            request_id=ctx.request_id,
        )

        logger.info(f"create_mortise_tenon result: {result}")
        return json.dumps(result)
    except Exception as e:
        logger.error(f"Error in create_mortise_tenon: {str(e)}")
        return f"Error creating mortise and tenon joint: {str(e)}"


@mcp.tool()
def create_dovetail(
    ctx: Context,
    tail_id: str,
    pin_id: str,
    width: float = 1.0,
    height: float = 1.0,
    depth: float = 1.0,
    angle: float = 15.0,
    num_tails: int = 3,
    offset_x: float = 0.0,
    offset_y: float = 0.0,
    offset_z: float = 0.0,
) -> str:
    """Create a dovetail joint between two components"""
    try:
        logger.info(
            f"create_dovetail called with tail_id={tail_id}, pin_id={pin_id}, width={width}, height={height}, depth={depth}, angle={angle}, num_tails={num_tails}"
        )

        sketchup = get_sketchup_connection()

        result = sketchup.send_command(
            method="tools/call",
            params={
                "name": "create_dovetail",
                "arguments": {
                    "tail_id": tail_id,
                    "pin_id": pin_id,
                    "width": width,
                    "height": height,
                    "depth": depth,
                    "angle": angle,
                    "num_tails": num_tails,
                    "offset_x": offset_x,
                    "offset_y": offset_y,
                    "offset_z": offset_z,
                },
            },
            request_id=ctx.request_id,
        )

        logger.info(f"create_dovetail result: {result}")
        return json.dumps(result)
    except Exception as e:
        logger.error(f"Error in create_dovetail: {str(e)}")
        return f"Error creating dovetail joint: {str(e)}"


@mcp.tool()
def create_finger_joint(
    ctx: Context,
    board1_id: str,
    board2_id: str,
    width: float = 1.0,
    height: float = 1.0,
    depth: float = 1.0,
    num_fingers: int = 5,
    offset_x: float = 0.0,
    offset_y: float = 0.0,
    offset_z: float = 0.0,
) -> str:
    """Create a finger joint (box joint) between two components"""
    try:
        logger.info(
            f"create_finger_joint called with board1_id={board1_id}, board2_id={board2_id}, width={width}, height={height}, depth={depth}, num_fingers={num_fingers}"
        )

        sketchup = get_sketchup_connection()

        result = sketchup.send_command(
            method="tools/call",
            params={
                "name": "create_finger_joint",
                "arguments": {
                    "board1_id": board1_id,
                    "board2_id": board2_id,
                    "width": width,
                    "height": height,
                    "depth": depth,
                    "num_fingers": num_fingers,
                    "offset_x": offset_x,
                    "offset_y": offset_y,
                    "offset_z": offset_z,
                },
            },
            request_id=ctx.request_id,
        )

        logger.info(f"create_finger_joint result: {result}")
        return json.dumps(result)
    except Exception as e:
        logger.error(f"Error in create_finger_joint: {str(e)}")
        return f"Error creating finger joint: {str(e)}"


@mcp.tool()
def eval_ruby(ctx: Context, code: str) -> str:
    """Evaluate arbitrary Ruby code in Sketchup"""
    try:
        logger.info(f"eval_ruby called with code length: {len(code)}")

        sketchup = get_sketchup_connection()

        result = sketchup.send_command(
            method="tools/call",
            params={"name": "eval_ruby", "arguments": {"code": code}},
            request_id=ctx.request_id,
        )

        logger.info(f"eval_ruby result: {result}")

        # Format the response to include the result
        response = {
            "success": True,
            "result": result.get("content", [{"text": "Success"}])[0].get(
                "text", "Success"
            )
            if isinstance(result.get("content"), list)
            and len(result.get("content", [])) > 0
            else "Success",
        }

        return json.dumps(response)
    except Exception as e:
        logger.error(f"Error in eval_ruby: {str(e)}")
        return json.dumps({"success": False, "error": str(e)})


# =============================================================================
# Selection Tools
# =============================================================================

@mcp.tool()
def get_selection_detailed(ctx: Context) -> str:
    """Get detailed information about currently selected entities.

    Returns comprehensive information including bounds, materials, layers,
    and other properties for all selected entities.
    """
    try:
        logger.info("get_selection_detailed called")

        sketchup = get_sketchup_connection()

        result = sketchup.send_command(
            method="tools/call",
            params={"name": "get_selection_detailed", "arguments": {}},
            request_id=ctx.request_id,
        )

        logger.info(f"get_selection_detailed result: {result}")
        return json.dumps(result)
    except Exception as e:
        logger.error(f"Error in get_selection_detailed: {str(e)}")
        return json.dumps({"success": False, "error": str(e)})


@mcp.tool()
def select_by_id(ctx: Context, entity_id: int, add_to_selection: bool = False) -> str:
    """Select an entity by its ID.

    Args:
        entity_id: The entity ID to select
        add_to_selection: If True, add to current selection; if False, replace selection
    """
    try:
        logger.info(f"select_by_id called for entity_id={entity_id}, add={add_to_selection}")

        sketchup = get_sketchup_connection()

        result = sketchup.send_command(
            method="tools/call",
            params={
                "name": "select_by_id",
                "arguments": {"entity_id": entity_id, "add_to_selection": add_to_selection},
            },
            request_id=ctx.request_id,
        )

        logger.info(f"select_by_id result: {result}")
        return json.dumps(result)
    except Exception as e:
        logger.error(f"Error in select_by_id: {str(e)}")
        return json.dumps({"success": False, "error": str(e)})


@mcp.tool()
def clear_selection(ctx: Context) -> str:
    """Clear the current selection in SketchUp."""
    try:
        logger.info("clear_selection called")

        sketchup = get_sketchup_connection()

        result = sketchup.send_command(
            method="tools/call",
            params={"name": "clear_selection", "arguments": {}},
            request_id=ctx.request_id,
        )

        logger.info(f"clear_selection result: {result}")
        return json.dumps(result)
    except Exception as e:
        logger.error(f"Error in clear_selection: {str(e)}")
        return json.dumps({"success": False, "error": str(e)})


@mcp.tool()
def select_by_bounding_box(
    ctx: Context,
    min_x: float,
    min_y: float,
    min_z: float,
    max_x: float,
    max_y: float,
    max_z: float,
    add_to_selection: bool = False
) -> str:
    """Select all entities within a bounding box.

    Args:
        min_x, min_y, min_z: Minimum corner of the bounding box
        max_x, max_y, max_z: Maximum corner of the bounding box
        add_to_selection: If True, add to current selection; if False, replace
    """
    try:
        logger.info(f"select_by_bounding_box called with bounds ({min_x},{min_y},{min_z}) to ({max_x},{max_y},{max_z})")

        sketchup = get_sketchup_connection()

        result = sketchup.send_command(
            method="tools/call",
            params={
                "name": "select_by_bounding_box",
                "arguments": {
                    "min_point": [min_x, min_y, min_z],
                    "max_point": [max_x, max_y, max_z],
                    "add_to_selection": add_to_selection,
                },
            },
            request_id=ctx.request_id,
        )

        logger.info(f"select_by_bounding_box result: {result}")
        return json.dumps(result)
    except Exception as e:
        logger.error(f"Error in select_by_bounding_box: {str(e)}")
        return json.dumps({"success": False, "error": str(e)})


# =============================================================================
# Entity Inspection Tools
# =============================================================================

@mcp.tool()
def get_entity_by_id(ctx: Context, entity_id: int) -> str:
    """Get detailed information about a specific entity by ID.

    Args:
        entity_id: The entity ID to look up
    """
    try:
        logger.info(f"get_entity_by_id called for entity_id={entity_id}")

        sketchup = get_sketchup_connection()

        result = sketchup.send_command(
            method="tools/call",
            params={"name": "get_entity_by_id", "arguments": {"entity_id": entity_id}},
            request_id=ctx.request_id,
        )

        logger.info(f"get_entity_by_id result: {result}")
        return json.dumps(result)
    except Exception as e:
        logger.error(f"Error in get_entity_by_id: {str(e)}")
        return json.dumps({"success": False, "error": str(e)})


@mcp.tool()
def list_entities(ctx: Context, entity_type: str = None, limit: int = 100) -> str:
    """List entities in the current model.

    Args:
        entity_type: Optional filter by type (e.g., 'Face', 'Edge', 'Group', 'ComponentInstance')
        limit: Maximum number of entities to return (default: 100)
    """
    try:
        logger.info(f"list_entities called with type={entity_type}, limit={limit}")

        sketchup = get_sketchup_connection()

        result = sketchup.send_command(
            method="tools/call",
            params={
                "name": "list_entities",
                "arguments": {"entity_type": entity_type, "limit": limit},
            },
            request_id=ctx.request_id,
        )

        logger.info(f"list_entities result: {result}")
        return json.dumps(result)
    except Exception as e:
        logger.error(f"Error in list_entities: {str(e)}")
        return json.dumps({"success": False, "error": str(e)})


@mcp.tool()
def get_entity_properties(ctx: Context, entity_id: int) -> str:
    """Get all properties of an entity including custom attributes.

    Args:
        entity_id: The entity ID to get properties for
    """
    try:
        logger.info(f"get_entity_properties called for entity_id={entity_id}")

        sketchup = get_sketchup_connection()

        result = sketchup.send_command(
            method="tools/call",
            params={"name": "get_entity_properties", "arguments": {"entity_id": entity_id}},
            request_id=ctx.request_id,
        )

        logger.info(f"get_entity_properties result: {result}")
        return json.dumps(result)
    except Exception as e:
        logger.error(f"Error in get_entity_properties: {str(e)}")
        return json.dumps({"success": False, "error": str(e)})


# =============================================================================
# Camera Tools
# =============================================================================

@mcp.tool()
def get_camera(ctx: Context) -> str:
    """Get the current camera position, target, and up vector."""
    try:
        logger.info("get_camera called")

        sketchup = get_sketchup_connection()

        result = sketchup.send_command(
            method="tools/call",
            params={"name": "get_camera", "arguments": {}},
            request_id=ctx.request_id,
        )

        logger.info(f"get_camera result: {result}")
        return json.dumps(result)
    except Exception as e:
        logger.error(f"Error in get_camera: {str(e)}")
        return json.dumps({"success": False, "error": str(e)})


@mcp.tool()
def set_camera(
    ctx: Context,
    eye_x: float,
    eye_y: float,
    eye_z: float,
    target_x: float,
    target_y: float,
    target_z: float,
    up_x: float = 0,
    up_y: float = 0,
    up_z: float = 1
) -> str:
    """Set the camera position and orientation.

    Args:
        eye_x, eye_y, eye_z: Camera position
        target_x, target_y, target_z: Point the camera is looking at
        up_x, up_y, up_z: Up vector (default is Z-up)
    """
    try:
        logger.info(f"set_camera called with eye=({eye_x},{eye_y},{eye_z}), target=({target_x},{target_y},{target_z})")

        sketchup = get_sketchup_connection()

        result = sketchup.send_command(
            method="tools/call",
            params={
                "name": "set_camera",
                "arguments": {
                    "eye": [eye_x, eye_y, eye_z],
                    "target": [target_x, target_y, target_z],
                    "up": [up_x, up_y, up_z],
                },
            },
            request_id=ctx.request_id,
        )

        logger.info(f"set_camera result: {result}")
        return json.dumps(result)
    except Exception as e:
        logger.error(f"Error in set_camera: {str(e)}")
        return json.dumps({"success": False, "error": str(e)})


@mcp.tool()
def zoom_selection(ctx: Context) -> str:
    """Zoom the view to fit the current selection."""
    try:
        logger.info("zoom_selection called")

        sketchup = get_sketchup_connection()

        result = sketchup.send_command(
            method="tools/call",
            params={"name": "zoom_selection", "arguments": {}},
            request_id=ctx.request_id,
        )

        logger.info(f"zoom_selection result: {result}")
        return json.dumps(result)
    except Exception as e:
        logger.error(f"Error in zoom_selection: {str(e)}")
        return json.dumps({"success": False, "error": str(e)})


@mcp.tool()
def zoom_extents(ctx: Context) -> str:
    """Zoom the view to fit the entire model."""
    try:
        logger.info("zoom_extents called")

        sketchup = get_sketchup_connection()

        result = sketchup.send_command(
            method="tools/call",
            params={"name": "zoom_extents", "arguments": {}},
            request_id=ctx.request_id,
        )

        logger.info(f"zoom_extents result: {result}")
        return json.dumps(result)
    except Exception as e:
        logger.error(f"Error in zoom_extents: {str(e)}")
        return json.dumps({"success": False, "error": str(e)})


# =============================================================================
# Model Info Tools
# =============================================================================

@mcp.tool()
def get_model_info(ctx: Context) -> str:
    """Get comprehensive information about the current model."""
    try:
        logger.info("get_model_info called")

        sketchup = get_sketchup_connection()

        result = sketchup.send_command(
            method="tools/call",
            params={"name": "get_model_info", "arguments": {}},
            request_id=ctx.request_id,
        )

        logger.info(f"get_model_info result: {result}")
        return json.dumps(result)
    except Exception as e:
        logger.error(f"Error in get_model_info: {str(e)}")
        return json.dumps({"success": False, "error": str(e)})


@mcp.tool()
def list_layers(ctx: Context) -> str:
    """List all layers in the current model."""
    try:
        logger.info("list_layers called")

        sketchup = get_sketchup_connection()

        result = sketchup.send_command(
            method="tools/call",
            params={"name": "list_layers", "arguments": {}},
            request_id=ctx.request_id,
        )

        logger.info(f"list_layers result: {result}")
        return json.dumps(result)
    except Exception as e:
        logger.error(f"Error in list_layers: {str(e)}")
        return json.dumps({"success": False, "error": str(e)})


@mcp.tool()
def list_materials(ctx: Context) -> str:
    """List all materials in the current model."""
    try:
        logger.info("list_materials called")

        sketchup = get_sketchup_connection()

        result = sketchup.send_command(
            method="tools/call",
            params={"name": "list_materials", "arguments": {}},
            request_id=ctx.request_id,
        )

        logger.info(f"list_materials result: {result}")
        return json.dumps(result)
    except Exception as e:
        logger.error(f"Error in list_materials: {str(e)}")
        return json.dumps({"success": False, "error": str(e)})


@mcp.tool()
def list_definitions(ctx: Context) -> str:
    """List all component definitions in the current model."""
    try:
        logger.info("list_definitions called")

        sketchup = get_sketchup_connection()

        result = sketchup.send_command(
            method="tools/call",
            params={"name": "list_definitions", "arguments": {}},
            request_id=ctx.request_id,
        )

        logger.info(f"list_definitions result: {result}")
        return json.dumps(result)
    except Exception as e:
        logger.error(f"Error in list_definitions: {str(e)}")
        return json.dumps({"success": False, "error": str(e)})


# =============================================================================
# Extension Development Tools
# =============================================================================

@mcp.tool()
def reload_extension(ctx: Context, extension_name: str) -> str:
    """Reload a Ruby extension in SketchUp.

    This is useful for hot-reloading code during development.

    Args:
        extension_name: Name of the extension to reload
    """
    try:
        logger.info(f"reload_extension called for: {extension_name}")

        sketchup = get_sketchup_connection()

        result = sketchup.send_command(
            method="tools/call",
            params={"name": "reload_extension", "arguments": {"extension_name": extension_name}},
            request_id=ctx.request_id,
        )

        logger.info(f"reload_extension result: {result}")
        return json.dumps(result)
    except Exception as e:
        logger.error(f"Error in reload_extension: {str(e)}")
        return json.dumps({"success": False, "error": str(e)})


@mcp.tool()
def reload_file(ctx: Context, file_path: str) -> str:
    """Reload a specific Ruby file in SketchUp.

    Args:
        file_path: Absolute path to the Ruby file to reload
    """
    try:
        logger.info(f"reload_file called for: {file_path}")

        sketchup = get_sketchup_connection()

        result = sketchup.send_command(
            method="tools/call",
            params={"name": "reload_file", "arguments": {"file_path": file_path}},
            request_id=ctx.request_id,
        )

        logger.info(f"reload_file result: {result}")
        return json.dumps(result)
    except Exception as e:
        logger.error(f"Error in reload_file: {str(e)}")
        return json.dumps({"success": False, "error": str(e)})


@mcp.tool()
def run_command(ctx: Context, command_id: str) -> str:
    """Run a SketchUp command by its ID.

    Args:
        command_id: The command ID to execute (e.g., "selectSelectionTool:")
    """
    try:
        logger.info(f"run_command called for: {command_id}")

        sketchup = get_sketchup_connection()

        result = sketchup.send_command(
            method="tools/call",
            params={"name": "run_command", "arguments": {"command_id": command_id}},
            request_id=ctx.request_id,
        )

        logger.info(f"run_command result: {result}")
        return json.dumps(result)
    except Exception as e:
        logger.error(f"Error in run_command: {str(e)}")
        return json.dumps({"success": False, "error": str(e)})


@mcp.tool()
def list_commands(ctx: Context) -> str:
    """List available SketchUp commands."""
    try:
        logger.info("list_commands called")

        sketchup = get_sketchup_connection()

        result = sketchup.send_command(
            method="tools/call",
            params={"name": "list_commands", "arguments": {}},
            request_id=ctx.request_id,
        )

        logger.info(f"list_commands result: {result}")
        return json.dumps(result)
    except Exception as e:
        logger.error(f"Error in list_commands: {str(e)}")
        return json.dumps({"success": False, "error": str(e)})


# =============================================================================
# Console and Logging Tools
# =============================================================================

@mcp.tool()
def get_console_logs(ctx: Context, limit: int = 100) -> str:
    """Get recent console logs from SketchUp.

    Args:
        limit: Maximum number of log lines to return (default: 100)
    """
    try:
        logger.info(f"get_console_logs called with limit={limit}")

        sketchup = get_sketchup_connection()

        result = sketchup.send_command(
            method="tools/call",
            params={"name": "get_console_logs", "arguments": {"limit": limit}},
            request_id=ctx.request_id,
        )

        logger.info(f"get_console_logs result: {result}")
        return json.dumps(result)
    except Exception as e:
        logger.error(f"Error in get_console_logs: {str(e)}")
        return json.dumps({"success": False, "error": str(e)})


@mcp.tool()
def clear_console(ctx: Context) -> str:
    """Clear the Ruby console in SketchUp."""
    try:
        logger.info("clear_console called")

        sketchup = get_sketchup_connection()

        result = sketchup.send_command(
            method="tools/call",
            params={"name": "clear_console", "arguments": {}},
            request_id=ctx.request_id,
        )

        logger.info(f"clear_console result: {result}")
        return json.dumps(result)
    except Exception as e:
        logger.error(f"Error in clear_console: {str(e)}")
        return json.dumps({"success": False, "error": str(e)})


@mcp.tool()
def show_ruby_console(ctx: Context) -> str:
    """Show the Ruby console window in SketchUp."""
    try:
        logger.info("show_ruby_console called")

        sketchup = get_sketchup_connection()

        result = sketchup.send_command(
            method="tools/call",
            params={"name": "show_ruby_console", "arguments": {}},
            request_id=ctx.request_id,
        )

        logger.info(f"show_ruby_console result: {result}")
        return json.dumps(result)
    except Exception as e:
        logger.error(f"Error in show_ruby_console: {str(e)}")
        return json.dumps({"success": False, "error": str(e)})


# =============================================================================
# Screenshot and Visualization Tools
# =============================================================================


@mcp.tool()
def take_screenshot(
    ctx: Context,
    filename: str = None,
    width: int = 1920,
    height: int = 1080,
    file_format: str = "png",
    transparent: bool = False,
    antialias: bool = True,
    save_path: str = None,
) -> str:
    """Take a screenshot of the current SketchUp view and save to file.

    Args:
        filename: Name of the screenshot file (without extension). Auto-generated if not provided.
        width: Screenshot width in pixels (default: 1920)
        height: Screenshot height in pixels (default: 1080)
        file_format: Image format - "png" or "jpg" (default: "png")
        transparent: Use transparent background (PNG only, default: False)
        antialias: Enable antialiasing (default: True)
        save_path: Directory to save screenshot. Uses temp dir if not specified.
    """
    try:
        logger.info(f"take_screenshot called with dimensions {width}x{height}")

        sketchup = get_sketchup_connection()

        result = sketchup.send_command(
            method="tools/call",
            params={
                "name": "take_screenshot",
                "arguments": {
                    "filename": filename,
                    "width": width,
                    "height": height,
                    "format": file_format,
                    "transparent": transparent,
                    "antialias": antialias,
                    "save_path": save_path,
                },
            },
            request_id=ctx.request_id,
        )

        logger.info(f"take_screenshot result: {result}")
        return json.dumps(result)
    except Exception as e:
        logger.error(f"Error in take_screenshot: {str(e)}")
        return json.dumps({"success": False, "error": str(e)})


# =============================================================================
# UrbanA Development Tools
# =============================================================================


@mcp.tool()
def get_buildings(
    ctx: Context, include_details: bool = True, filter_selected: bool = False
) -> str:
    """Get buildings from UrbanA::Core.state.su2ua_buildings.

    This is useful for development and debugging of the UrbanA extension.
    Returns information about all tracked buildings in the current model.

    Args:
        include_details: If True, includes detailed building properties like
                        UCVs, parameters, land use, etc. (default: True)
        filter_selected: If True, only returns currently selected buildings (default: False)
    """
    try:
        logger.info(
            f"get_buildings called with include_details={include_details}, filter_selected={filter_selected}"
        )

        sketchup = get_sketchup_connection()

        result = sketchup.send_command(
            method="tools/call",
            params={
                "name": "get_buildings",
                "arguments": {
                    "include_details": include_details,
                    "filter_selected": filter_selected,
                },
            },
            request_id=ctx.request_id,
        )

        logger.info(f"get_buildings result: {result}")
        return json.dumps(result)
    except Exception as e:
        logger.error(f"Error in get_buildings: {str(e)}")
        return json.dumps({"success": False, "error": str(e)})


@mcp.tool()
def get_urbanA_state_summary(ctx: Context) -> str:
    """Get a summary of UrbanA::Core.state for quick debugging.

    Returns key statistics about the current UrbanA state including:
    - Number of tracked buildings
    - Number of blocks
    - Selected buildings count
    - Selected blocks count
    - Project info (if available)
    - Land use count
    - Street type count
    """
    try:
        logger.info("get_urbanA_state_summary called")

        sketchup = get_sketchup_connection()

        result = sketchup.send_command(
            method="tools/call",
            params={"name": "get_urbanA_state_summary", "arguments": {}},
            request_id=ctx.request_id,
        )

        logger.info(f"get_urbanA_state_summary result: {result}")
        return json.dumps(result)
    except Exception as e:
        logger.error(f"Error in get_urbanA_state_summary: {str(e)}")
        return json.dumps({"success": False, "error": str(e)})


@mcp.tool()
def get_selected_buildings(ctx: Context) -> str:
    """Get details about currently selected UrbanA buildings.

    Returns the UrbanA Building objects corresponding to the
    UrbanA::Core.state.selected_buildings paths.
    """
    try:
        logger.info("get_selected_buildings called")

        sketchup = get_sketchup_connection()

        result = sketchup.send_command(
            method="tools/call",
            params={"name": "get_selected_buildings", "arguments": {}},
            request_id=ctx.request_id,
        )

        logger.info(f"get_selected_buildings result: {result}")
        return json.dumps(result)
    except Exception as e:
        logger.error(f"Error in get_selected_buildings: {str(e)}")
        return json.dumps({"success": False, "error": str(e)})


@mcp.tool()
def run_urbanA_query(ctx: Context, ruby_code: str) -> str:
    """Execute UrbanA-specific Ruby code with automatic UrbanA module context.

    This tool automatically wraps your code to provide convenient access to
    UrbanA modules and state. The following variables are pre-defined:
    - state: UrbanA::Core.state
    - buildings: UrbanA::Core.state.su2ua_buildings
    - project: UrbanA::Core.state.project (if available)
    - model: Sketchup.active_model
    - selection: Sketchup.active_model.selection

    Args:
        ruby_code: Ruby code to execute. Can use pre-defined variables above.
                   Return value will be captured and returned as JSON.

    Example queries:
    - "buildings.values.map { |b| b.land_use }" - get all land uses
    - "buildings.size" - count buildings
    - "state.selected_buildings.map { |path| path.last.entityID }" - get selected IDs
    """
    try:
        logger.info(f"run_urbanA_query called with code: {ruby_code[:100]}...")

        # Wrap the code with UrbanA context
        wrapped_code = f"""
begin
  # UrbanA context setup
  state = UrbanA::Core.state rescue nil
  buildings = state ? state.su2ua_buildings : {{}}
  blocks = state ? state.su2ua_blocks : {{}}
  project = state ? state.project : nil
  model = Sketchup.active_model
  selection = model.selection
  
  # User code
  result = begin
    {ruby_code}
  rescue => e
    {{error: e.message, backtrace: e.backtrace.first(5)}}
  end
  
  # Serialize result
  case result
  when Hash
    result.to_json
  when Array
    result.to_json
  when String, Numeric, true, false, nil
    result.to_json
  else
    {{type: result.class.name, value: result.to_s}}.to_json
  end
rescue => e
  {{error: e.message, backtrace: e.backtrace.first(5)}}.to_json
end
"""

        sketchup = get_sketchup_connection()

        result = sketchup.send_command(
            method="tools/call",
            params={"name": "eval_ruby", "arguments": {"code": wrapped_code}},
            request_id=ctx.request_id,
        )

        # Parse and format the result
        content_text = result.get("content", [{"text": "{}"}])[0].get("text", "{}")
        try:
            parsed = json.loads(content_text)
            return json.dumps({"success": True, "result": parsed})
        except json.JSONDecodeError:
            return json.dumps({"success": True, "result": content_text})

    except Exception as e:
        logger.error(f"Error in run_urbanA_query: {str(e)}")
        return json.dumps({"success": False, "error": str(e)})


@mcp.tool()
def get_entity_info(
    ctx: Context, entity_id: int = None, entity_name: str = None
) -> str:
    """Get detailed information about a SketchUp entity by ID or name.

    Useful for debugging entity relationships and checking if an entity
    is tracked by UrbanA.

    Args:
        entity_id: SketchUp entity ID to look up
        entity_name: Entity name to search for (if ID not provided)
    """
    try:
        logger.info(
            f"get_entity_info called for entity_id={entity_id}, name={entity_name}"
        )

        sketchup = get_sketchup_connection()

        result = sketchup.send_command(
            method="tools/call",
            params={
                "name": "get_entity_info",
                "arguments": {"entity_id": entity_id, "entity_name": entity_name},
            },
            request_id=ctx.request_id,
        )

        logger.info(f"get_entity_info result: {result}")
        return json.dumps(result)
    except Exception as e:
        logger.error(f"Error in get_entity_info: {str(e)}")
        return json.dumps({"success": False, "error": str(e)})


@mcp.tool()
def refresh_urbanA(ctx: Context) -> str:
    """Refresh UrbanA state by re-scanning the model.

    Forces UrbanA to update its internal state from the current SketchUp model.
    Useful after making changes to geometry or when buildings aren't showing
    correctly in the UrbanA state.

    Returns updated building and block counts after refresh.
    """
    try:
        logger.info("refresh_urbanA called")

        sketchup = get_sketchup_connection()

        result = sketchup.send_command(
            method="tools/call",
            params={"name": "refresh_urbanA", "arguments": {}},
            request_id=ctx.request_id,
        )

        logger.info(f"refresh_urbanA result: {result}")
        return json.dumps(result)
    except Exception as e:
        logger.error(f"Error in refresh_urbanA: {str(e)}")
        return json.dumps({"success": False, "error": str(e)})


@mcp.tool()
def set_building_land_use(
    ctx: Context,
    entity_id: int,
    land_use: str
) -> str:
    """Set the land use for an UrbanA building.

    Changes the land_use property of a building tracked by UrbanA.
    This will update the building's parameters and may trigger UCV recalculation.

    Args:
        entity_id: SketchUp entity ID of the building
        land_use: New land use string (e.g., "residential", "commercial", "office")

    Returns:
        Result with old and new land use values.
    """
    try:
        logger.info(f"set_building_land_use called for entity_id={entity_id}, land_use={land_use}")

        sketchup = get_sketchup_connection()

        result = sketchup.send_command(
            method="tools/call",
            params={
                "name": "set_building_land_use",
                "arguments": {"entity_id": entity_id, "land_use": land_use},
            },
            request_id=ctx.request_id,
        )

        logger.info(f"set_building_land_use result: {result}")
        return json.dumps(result)
    except Exception as e:
        logger.error(f"Error in set_building_land_use: {str(e)}")
        return json.dumps({"success": False, "error": str(e)})


def main():
    mcp.run()


if __name__ == "__main__":
    main()
