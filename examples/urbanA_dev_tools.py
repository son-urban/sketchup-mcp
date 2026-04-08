#!/usr/bin/env python3
"""
UrbanA Development Tools Example

This example demonstrates how to use the MCP tools for UrbanA extension development.
These tools help inspect and debug the UrbanA state while developing.

Prerequisites:
- SketchUp with UrbanA extension loaded
- su_mcp extension running (socket server on port 9876)
- sketchup-mcp Python server running

Usage with Claude Code:
1. Start the SketchUp MCP server
2. Use these tools via Claude Code's tool system
"""

import json
import asyncio
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

# Server parameters for Claude Code stdio connection
server_params = StdioServerParameters(
    command="python",
    args=["-m", "sketchup_mcp.server"],
)


async def get_buildings_example():
    """Example: Get all buildings from UrbanA state."""
    async with stdio_client(server_params) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()

            # Get all buildings with details
            result = await session.call_tool("get_buildings", {
                "include_details": True,
                "filter_selected": False
            })
            print("Buildings:", json.dumps(result, indent=2))


async def get_state_summary_example():
    """Example: Get UrbanA state summary for quick debugging."""
    async with stdio_client(server_params) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()

            result = await session.call_tool("get_urbanA_state_summary", {})
            print("State Summary:", json.dumps(result, indent=2))


async def get_selected_buildings_example():
    """Example: Get currently selected UrbanA buildings."""
    async with stdio_client(server_params) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()

            result = await session.call_tool("get_selected_buildings", {})
            print("Selected Buildings:", json.dumps(result, indent=2))


async def run_urbanA_query_example():
    """Example: Run custom UrbanA Ruby queries."""
    async with stdio_client(server_params) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()

            # Query 1: Get all land uses
            result = await session.call_tool("run_urbanA_query", {
                "ruby_code": "buildings.values.map { |b| b.land_use }.uniq"
            })
            print("Land Uses:", json.dumps(result, indent=2))

            # Query 2: Count buildings by land use
            result = await session.call_tool("run_urbanA_query", {
                "ruby_code": "buildings.values.group_by { |b| b.land_use }.transform_values(&:count)"
            })
            print("Buildings by Land Use:", json.dumps(result, indent=2))

            # Query 3: Get total GFA
            result = await session.call_tool("run_urbanA_query", {
                "ruby_code": "
                    total_gfa = 0
                    buildings.values.each do |b|
                        if b.respond_to?(:ucvs) && b.ucvs[:UCV_gross_floor_area]
                            total_gfa += b.ucvs[:UCV_gross_floor_area].external_value.to_f
                        end
                    end
                    { total_gfa: total_gfa, unit: 'm2' }
                "
            })
            print("Total GFA:", json.dumps(result, indent=2))


async def take_screenshot_example():
    """Example: Take a screenshot of the current view."""
    async with stdio_client(server_params) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()

            result = await session.call_tool("take_screenshot", {
                "filename": "urbanA_debug_view",
                "width": 1920,
                "height": 1080,
                "file_format": "png",
                "antialias": True
            })
            print("Screenshot:", json.dumps(result, indent=2))


async def get_entity_info_example():
    """Example: Get detailed info about a specific entity."""
    async with stdio_client(server_params) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()

            # Get info by entity ID
            result = await session.call_tool("get_entity_info", {
                "entity_id": 12345
            })
            print("Entity Info:", json.dumps(result, indent=2))


async def refresh_urbanA_example():
    """Example: Refresh UrbanA state after making model changes."""
    async with stdio_client(server_params) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()

            print("Refreshing UrbanA state...")
            result = await session.call_tool("refresh_urbanA", {})
            print(f"Result: {json.dumps(result, indent=2)}")


async def set_land_use_example():
    """Example: Change a building's land use."""
    async with stdio_client(server_params) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()

            # Change land use for entity ID 12345
            result = await session.call_tool("set_building_land_use", {
                "entity_id": 12345,
                "land_use": "residential"
            })
            print(f"Result: {json.dumps(result, indent=2)}")


async def development_workflow_example():
    """
    Complete development workflow example.

    This demonstrates a typical UrbanA development debugging session:
    1. Take a screenshot to see current state
    2. Get state summary
    3. Inspect selected buildings
    4. Run custom queries
    5. Make changes (e.g., set land use)
    6. Refresh and verify
    """
    async with stdio_client(server_params) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()

            print("=== UrbanA Development Debug Session ===\n")

            # Step 1: Screenshot
            print("1. Taking screenshot...")
            screenshot = await session.call_tool("take_screenshot", {
                "filename": "debug_session",
                "width": 1920,
                "height": 1080
            })
            print(f"   Screenshot saved to: {screenshot.get('path', 'unknown')}\n")

            # Step 2: State summary
            print("2. Getting UrbanA state summary...")
            summary = await session.call_tool("get_urbanA_state_summary", {})
            print(f"   Buildings: {summary.get('building_count', 0)}")
            print(f"   Selected: {summary.get('selected_buildings_count', 0)}")
            print(f"   Land uses: {summary.get('land_use_count', 0)}\n")

            # Step 3: Selected buildings
            print("3. Inspecting selected buildings...")
            selected = await session.call_tool("get_selected_buildings", {})
            for b in selected.get("selected_buildings", []):
                print(f"   - {b.get('entity_name', 'unnamed')} ({b.get('land_use', 'unknown')})")

            # Step 4: Custom query for building heights
            print("\n4. Running custom height query...")
            heights = await session.call_tool("run_urbanA_query", {
                "ruby_code": "
                    buildings.values.map { |b|
                        height = b.ucvs[:UCV_height] rescue nil
                        {
                            name: b.building_id,
                            land_use: b.land_use,
                            height: height ? height.external_value : nil
                        }
                    }.compact
                "
            })
            print(f"   Heights: {json.dumps(heights, indent=2)}\n")

            # Step 5: Refresh state (if needed after changes)
            print("5. Refreshing UrbanA state...")
            refresh = await session.call_tool("refresh_urbanA", {})
            print(f"   Refreshed. Building count: {refresh.get('building_count', 0)}\n")

            print("=== Debug session complete ===")


if __name__ == "__main__":
    # Run any example
    print("UrbanA Development Tools Examples")
    print("=" * 50)
    print("\nAvailable examples:")
    print("  1. get_buildings_example() - Get all UrbanA buildings")
    print("  2. get_state_summary_example() - Quick state overview")
    print("  3. get_selected_buildings_example() - Inspect selection")
    print("  4. run_urbanA_query_example() - Run custom Ruby queries")
    print("  5. take_screenshot_example() - Capture current view")
    print("  6. get_entity_info_example() - Inspect specific entity")
    print("  7. refresh_urbanA_example() - Refresh UrbanA state")
    print("  8. set_land_use_example() - Change building land use")
    print("  9. development_workflow_example() - Full debug session")
    print("\nUncomment the example you want to run in the script.")

    # Uncomment to run an example:
    # asyncio.run(get_state_summary_example())
    # asyncio.run(development_workflow_example())
