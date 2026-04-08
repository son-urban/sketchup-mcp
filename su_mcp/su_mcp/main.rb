require 'sketchup'
require 'json'
require 'socket'
require 'fileutils'

puts "MCP Extension loading..."
SKETCHUP_CONSOLE.show rescue nil

module SU_MCP
  class Server
    def initialize
      @port = 9876
      @server = nil
      @running = false
      @timer_id = nil
      
      # Try multiple ways to show console
      begin
        SKETCHUP_CONSOLE.show
      rescue
        begin
          Sketchup.send_action("showRubyPanel:")
        rescue
          UI.start_timer(0) { SKETCHUP_CONSOLE.show }
        end
      end
    end

    def log(msg)
      begin
        SKETCHUP_CONSOLE.write("MCP: #{msg}\n")
      rescue
        puts "MCP: #{msg}"
      end
      STDOUT.flush
    end

    def start
      return if @running
      
      begin
        log "Starting server on localhost:#{@port}..."
        
        @server = TCPServer.new('127.0.0.1', @port)
        log "Server created on port #{@port}"
        
        @running = true
        
        @timer_id = UI.start_timer(0.1, true) {
          begin
            if @running
              # Check for connection
              ready = IO.select([@server], nil, nil, 0)
              if ready
                log "Connection waiting..."
                client = @server.accept_nonblock
                log "Client accepted"
                
                data = client.gets
                log "Raw data: #{data.inspect}"
                
                if data
                  begin
                    # Parse the raw JSON first to check format
                    raw_request = JSON.parse(data)
                    log "Raw parsed request: #{raw_request.inspect}"
                    
                    # Extract the original request ID if it exists in the raw data
                    original_id = nil
                    if data =~ /"id":\s*(\d+)/
                      original_id = $1.to_i
                      log "Found original request ID: #{original_id}"
                    end
                    
                    # Use the raw request directly without transforming it
                    # Just ensure the ID is preserved if it exists
                    request = raw_request
                    if !request["id"] && original_id
                      request["id"] = original_id
                      log "Added missing ID: #{original_id}"
                    end
                    
                    log "Processed request: #{request.inspect}"
                    response = handle_jsonrpc_request(request)
                    response_json = response.to_json + "\n"
                    
                    log "Sending response: #{response_json.strip}"
                    client.write(response_json)
                    client.flush
                    log "Response sent"
                  rescue JSON::ParserError => e
                    log "JSON parse error: #{e.message}"
                    error_response = {
                      jsonrpc: "2.0",
                      error: { code: -32700, message: "Parse error" },
                      id: original_id
                    }.to_json + "\n"
                    client.write(error_response)
                    client.flush
                  rescue StandardError => e
                    log "Request error: #{e.message}"
                    error_response = {
                      jsonrpc: "2.0",
                      error: { code: -32603, message: e.message },
                      id: request ? request["id"] : original_id
                    }.to_json + "\n"
                    client.write(error_response)
                    client.flush
                  end
                end
                
                client.close
                log "Client closed"
              end
            end
          rescue IO::WaitReadable
            # Normal for accept_nonblock
          rescue StandardError => e
            log "Timer error: #{e.message}"
            log e.backtrace.join("\n")
          end
        }
        
        log "Server started and listening"
        
      rescue StandardError => e
        log "Error: #{e.message}"
        log e.backtrace.join("\n")
        stop
      end
    end

    def stop
      log "Stopping server..."
      @running = false
      
      if @timer_id
        UI.stop_timer(@timer_id)
        @timer_id = nil
      end
      
      @server.close if @server
      @server = nil
      log "Server stopped"
    end

    private

    def handle_jsonrpc_request(request)
      log "Handling JSONRPC request: #{request.inspect}"
      
      # Handle direct command format (for backward compatibility)
      if request["command"]
        tool_request = {
          "method" => "tools/call",
          "params" => {
            "name" => request["command"],
            "arguments" => request["parameters"]
          },
          "jsonrpc" => request["jsonrpc"] || "2.0",
          "id" => request["id"]
        }
        log "Converting to tool request: #{tool_request.inspect}"
        return handle_tool_call(tool_request)
      end

      # Handle jsonrpc format
      case request["method"]
      when "tools/call"
        handle_tool_call(request)
      when "resources/list"
        {
          jsonrpc: request["jsonrpc"] || "2.0",
          result: { 
            resources: list_resources,
            success: true
          },
          id: request["id"]
        }
      when "prompts/list"
        {
          jsonrpc: request["jsonrpc"] || "2.0",
          result: { 
            prompts: [],
            success: true
          },
          id: request["id"]
        }
      else
        {
          jsonrpc: request["jsonrpc"] || "2.0",
          error: { 
            code: -32601, 
            message: "Method not found",
            data: { success: false }
          },
          id: request["id"]
        }
      end
    end

    def list_resources
      model = Sketchup.active_model
      return [] unless model
      
      model.entities.map do |entity|
        {
          id: entity.entityID,
          type: entity.typename.downcase
        }
      end
    end

    def handle_tool_call(request)
      log "Handling tool call: #{request.inspect}"
      tool_name = request["params"]["name"]
      args = request["params"]["arguments"]

      begin
        result = case tool_name
        when "create_component"
          create_component(args)
        when "delete_component"
          delete_component(args)
        when "transform_component"
          transform_component(args)
        when "get_selection"
          get_selection
        when "export", "export_scene"
          export_scene(args)
        when "set_material"
          set_material(args)
        when "eval_ruby"
          eval_ruby(args)
        when "take_screenshot"
          take_screenshot(args)
        when "get_buildings"
          get_buildings(args)
        when "get_urbanA_state_summary"
          get_urbanA_state_summary(args)
        when "get_selected_buildings"
          get_selected_buildings(args)
        when "get_entity_info"
          get_entity_info(args)
        when "refresh_urbanA"
          refresh_urbanA(args)
        when "set_building_land_use"
          set_building_land_use(args)
        when "start_operation"
          start_operation(args)
        when "commit_operation"
          commit_operation(args)
        when "abort_operation"
          abort_operation(args)
        when "undo"
          undo(args)
        when "redo"
          redo_operation(args)
        when "get_selection_detailed"
          get_selection_detailed(args)
        when "select_by_id"
          select_by_id(args)
        when "clear_selection"
          clear_selection(args)
        when "select_by_bounding_box"
          select_by_bounding_box(args)
        when "get_entity_by_id"
          get_entity_by_id(args)
        when "list_entities"
          list_entities(args)
        when "get_entity_properties"
          get_entity_properties(args)
        when "get_camera"
          get_camera(args)
        when "set_camera"
          set_camera(args)
        when "zoom_selection"
          zoom_selection(args)
        when "zoom_extents"
          zoom_extents(args)
        when "get_model_info"
          get_model_info(args)
        when "list_layers"
          list_layers(args)
        when "list_materials"
          list_materials(args)
        when "list_definitions"
          list_definitions(args)
        when "reload_extension"
          reload_extension(args)
        when "reload_file"
          reload_file(args)
        when "run_command"
          run_command(args)
        when "list_commands"
          list_commands(args)
        when "get_console_logs"
          get_console_logs(args)
        when "clear_console"
          clear_console(args)
        when "show_ruby_console"
          show_ruby_console(args)
        else
          raise "Unknown tool: #{tool_name}"
        end

        log "Tool call result: #{result.inspect}"
        if result[:success]
          response = {
            jsonrpc: request["jsonrpc"] || "2.0",
            result: {
              content: [{ type: "text", text: result[:result] || "Success" }],
              isError: false,
              success: true,
              resourceId: result[:id]
            },
            id: request["id"]
          }
          log "Sending success response: #{response.inspect}"
          response
        else
          response = {
            jsonrpc: request["jsonrpc"] || "2.0",
            error: { 
              code: -32603, 
              message: "Operation failed",
              data: { success: false }
            },
            id: request["id"]
          }
          log "Sending error response: #{response.inspect}"
          response
        end
      rescue StandardError => e
        log "Tool call error: #{e.message}"
        response = {
          jsonrpc: request["jsonrpc"] || "2.0",
          error: { 
            code: -32603, 
            message: e.message,
            data: { success: false }
          },
          id: request["id"]
        }
        log "Sending error response: #{response.inspect}"
        response
      end
    end

    def create_component(params)
      log "Creating component with params: #{params.inspect}"
      model = Sketchup.active_model
      log "Got active model: #{model.inspect}"
      entities = model.active_entities
      log "Got active entities: #{entities.inspect}"
      
      pos = params["position"] || [0,0,0]
      dims = params["dimensions"] || [1,1,1]
      
      case params["type"]
      when "cube"
        log "Creating cube at position #{pos.inspect} with dimensions #{dims.inspect}"
        
        begin
          group = entities.add_group
          log "Created group: #{group.inspect}"
          
          face = group.entities.add_face(
            [pos[0], pos[1], pos[2]],
            [pos[0] + dims[0], pos[1], pos[2]],
            [pos[0] + dims[0], pos[1] + dims[1], pos[2]],
            [pos[0], pos[1] + dims[1], pos[2]]
          )
          log "Created face: #{face.inspect}"
          
          face.pushpull(dims[2])
          log "Pushed/pulled face by #{dims[2]}"
          
          result = { 
            id: group.entityID,
            success: true
          }
          log "Returning result: #{result.inspect}"
          result
        rescue StandardError => e
          log "Error in create_component: #{e.message}"
          log e.backtrace.join("\n")
          raise
        end
      when "cylinder"
        log "Creating cylinder at position #{pos.inspect} with dimensions #{dims.inspect}"
        
        begin
          # Create a group to contain the cylinder
          group = entities.add_group
          
          # Extract dimensions
          radius = dims[0] / 2.0
          height = dims[2]
          
          # Create a circle at the base
          center = [pos[0] + radius, pos[1] + radius, pos[2]]
          
          # Create points for a circle
          num_segments = 24  # Number of segments for the circle
          circle_points = []
          
          num_segments.times do |i|
            angle = Math::PI * 2 * i / num_segments
            x = center[0] + radius * Math.cos(angle)
            y = center[1] + radius * Math.sin(angle)
            z = center[2]
            circle_points << [x, y, z]
          end
          
          # Create the circular face
          face = group.entities.add_face(circle_points)
          
          # Extrude the face to create the cylinder
          face.pushpull(height)
          
          result = { 
            id: group.entityID,
            success: true
          }
          log "Created cylinder, returning result: #{result.inspect}"
          result
        rescue StandardError => e
          log "Error creating cylinder: #{e.message}"
          log e.backtrace.join("\n")
          raise
        end
      when "sphere"
        log "Creating sphere at position #{pos.inspect} with dimensions #{dims.inspect}"
        
        begin
          # Create a group to contain the sphere
          group = entities.add_group
          
          # Extract dimensions
          radius = dims[0] / 2.0
          center = [pos[0] + radius, pos[1] + radius, pos[2] + radius]
          
          # Use SketchUp's built-in sphere method if available
          if Sketchup::Tools.respond_to?(:create_sphere)
            Sketchup::Tools.create_sphere(center, radius, 24, group.entities)
          else
            # Fallback implementation using polygons
            # Create a UV sphere with latitude and longitude segments
            segments = 16
            
            # Create points for the sphere
            points = []
            for lat_i in 0..segments
              lat = Math::PI * lat_i / segments
              for lon_i in 0..segments
                lon = 2 * Math::PI * lon_i / segments
                x = center[0] + radius * Math.sin(lat) * Math.cos(lon)
                y = center[1] + radius * Math.sin(lat) * Math.sin(lon)
                z = center[2] + radius * Math.cos(lat)
                points << [x, y, z]
              end
            end
            
            # Create faces for the sphere (simplified approach)
            for lat_i in 0...segments
              for lon_i in 0...segments
                i1 = lat_i * (segments + 1) + lon_i
                i2 = i1 + 1
                i3 = i1 + segments + 1
                i4 = i3 + 1
                
                # Create a quad face
                begin
                  group.entities.add_face(points[i1], points[i2], points[i4], points[i3])
                rescue StandardError => e
                  # Skip faces that can't be created (may happen at poles)
                  log "Skipping face: #{e.message}"
                end
              end
            end
          end
          
          result = { 
            id: group.entityID,
            success: true
          }
          log "Created sphere, returning result: #{result.inspect}"
          result
        rescue StandardError => e
          log "Error creating sphere: #{e.message}"
          log e.backtrace.join("\n")
          raise
        end
      when "cone"
        log "Creating cone at position #{pos.inspect} with dimensions #{dims.inspect}"
        
        begin
          # Create a group to contain the cone
          group = entities.add_group
          
          # Extract dimensions
          radius = dims[0] / 2.0
          height = dims[2]
          
          # Create a circle at the base
          center = [pos[0] + radius, pos[1] + radius, pos[2]]
          apex = [center[0], center[1], center[2] + height]
          
          # Create points for a circle
          num_segments = 24  # Number of segments for the circle
          circle_points = []
          
          num_segments.times do |i|
            angle = Math::PI * 2 * i / num_segments
            x = center[0] + radius * Math.cos(angle)
            y = center[1] + radius * Math.sin(angle)
            z = center[2]
            circle_points << [x, y, z]
          end
          
          # Create the circular face for the base
          base = group.entities.add_face(circle_points)
          
          # Create the cone sides
          (0...num_segments).each do |i|
            j = (i + 1) % num_segments
            # Create a triangular face from two adjacent points on the circle to the apex
            group.entities.add_face(circle_points[i], circle_points[j], apex)
          end
          
          result = { 
            id: group.entityID,
            success: true
          }
          log "Created cone, returning result: #{result.inspect}"
          result
        rescue StandardError => e
          log "Error creating cone: #{e.message}"
          log e.backtrace.join("\n")
          raise
        end
      else
        raise "Unknown component type: #{params["type"]}"
      end
    end

    def delete_component(params)
      model = Sketchup.active_model
      
      # Handle ID format - strip quotes if present
      id_str = params["id"].to_s.gsub('"', '')
      log "Looking for entity with ID: #{id_str}"
      
      entity = model.find_entity_by_id(id_str.to_i)
      
      if entity
        log "Found entity: #{entity.inspect}"
        entity.erase!
        { success: true }
      else
        raise "Entity not found"
      end
    end

    def transform_component(params)
      model = Sketchup.active_model
      
      # Handle ID format - strip quotes if present
      id_str = params["id"].to_s.gsub('"', '')
      log "Looking for entity with ID: #{id_str}"
      
      entity = model.find_entity_by_id(id_str.to_i)
      
      if entity
        log "Found entity: #{entity.inspect}"
        
        # Handle position
        if params["position"]
          pos = params["position"]
          log "Transforming position to #{pos.inspect}"
          
          # Create a transformation to move the entity
          translation = Geom::Transformation.translation(Geom::Point3d.new(pos[0], pos[1], pos[2]))
          entity.transform!(translation)
        end
        
        # Handle rotation (in degrees)
        if params["rotation"]
          rot = params["rotation"]
          log "Rotating by #{rot.inspect} degrees"
          
          # Convert to radians
          x_rot = rot[0] * Math::PI / 180
          y_rot = rot[1] * Math::PI / 180
          z_rot = rot[2] * Math::PI / 180
          
          # Apply rotations
          if rot[0] != 0
            rotation = Geom::Transformation.rotation(entity.bounds.center, Geom::Vector3d.new(1, 0, 0), x_rot)
            entity.transform!(rotation)
          end
          
          if rot[1] != 0
            rotation = Geom::Transformation.rotation(entity.bounds.center, Geom::Vector3d.new(0, 1, 0), y_rot)
            entity.transform!(rotation)
          end
          
          if rot[2] != 0
            rotation = Geom::Transformation.rotation(entity.bounds.center, Geom::Vector3d.new(0, 0, 1), z_rot)
            entity.transform!(rotation)
          end
        end
        
        # Handle scale
        if params["scale"]
          scale = params["scale"]
          log "Scaling by #{scale.inspect}"
          
          # Create a transformation to scale the entity
          center = entity.bounds.center
          scaling = Geom::Transformation.scaling(center, scale[0], scale[1], scale[2])
          entity.transform!(scaling)
        end
        
        { success: true, id: entity.entityID }
      else
        raise "Entity not found"
      end
    end

    def get_selection
      model = Sketchup.active_model
      selection = model.selection
      
      log "Getting selection, count: #{selection.length}"
      
      selected_entities = selection.map do |entity|
        {
          id: entity.entityID,
          type: entity.typename.downcase
        }
      end
      
      { success: true, entities: selected_entities }
    end
    
    def export_scene(params)
      log "Exporting scene with params: #{params.inspect}"
      model = Sketchup.active_model
      
      format = params["format"] || "skp"
      
      begin
        # Create a temporary directory for exports
        temp_dir = File.join(ENV['TEMP'] || ENV['TMP'] || Dir.tmpdir, "sketchup_exports")
        FileUtils.mkdir_p(temp_dir) unless Dir.exist?(temp_dir)
        
        # Generate a unique filename
        timestamp = Time.now.strftime("%Y%m%d_%H%M%S")
        filename = "sketchup_export_#{timestamp}"
        
        case format.downcase
        when "skp"
          # Export as SketchUp file
          export_path = File.join(temp_dir, "#{filename}.skp")
          log "Exporting to SketchUp file: #{export_path}"
          model.save(export_path)
          
        when "obj"
          # Export as OBJ file
          export_path = File.join(temp_dir, "#{filename}.obj")
          log "Exporting to OBJ file: #{export_path}"
          
          # Check if OBJ exporter is available
          if Sketchup.require("sketchup.rb")
            options = {
              :triangulated_faces => true,
              :double_sided_faces => true,
              :edges => false,
              :texture_maps => true
            }
            model.export(export_path, options)
          else
            raise "OBJ exporter not available"
          end
          
        when "dae"
          # Export as COLLADA file
          export_path = File.join(temp_dir, "#{filename}.dae")
          log "Exporting to COLLADA file: #{export_path}"
          
          # Check if COLLADA exporter is available
          if Sketchup.require("sketchup.rb")
            options = { :triangulated_faces => true }
            model.export(export_path, options)
          else
            raise "COLLADA exporter not available"
          end
          
        when "stl"
          # Export as STL file
          export_path = File.join(temp_dir, "#{filename}.stl")
          log "Exporting to STL file: #{export_path}"
          
          # Check if STL exporter is available
          if Sketchup.require("sketchup.rb")
            options = { :units => "model" }
            model.export(export_path, options)
          else
            raise "STL exporter not available"
          end
          
        when "png", "jpg", "jpeg"
          # Export as image
          ext = format.downcase == "jpg" ? "jpeg" : format.downcase
          export_path = File.join(temp_dir, "#{filename}.#{ext}")
          log "Exporting to image file: #{export_path}"
          
          # Get the current view
          view = model.active_view
          
          # Set up options for the export
          options = {
            :filename => export_path,
            :width => params["width"] || 1920,
            :height => params["height"] || 1080,
            :antialias => true,
            :transparent => (ext == "png")
          }
          
          # Export the image
          view.write_image(options)
          
        else
          raise "Unsupported export format: #{format}"
        end
        
        log "Export completed successfully to: #{export_path}"
        
        { 
          success: true, 
          path: export_path,
          format: format
        }
      rescue StandardError => e
        log "Error in export_scene: #{e.message}"
        log e.backtrace.join("\n")
        raise
      end
    end
    
    def set_material(params)
      log "Setting material with params: #{params.inspect}"
      model = Sketchup.active_model
      
      # Handle ID format - strip quotes if present
      id_str = params["id"].to_s.gsub('"', '')
      log "Looking for entity with ID: #{id_str}"
      
      entity = model.find_entity_by_id(id_str.to_i)
      
      if entity
        log "Found entity: #{entity.inspect}"
        
        material_name = params["material"]
        log "Setting material to: #{material_name}"
        
        # Get or create the material
        material = model.materials[material_name]
        if !material
          # Create a new material if it doesn't exist
          material = model.materials.add(material_name)
          
          # Handle color specification
          case material_name.downcase
          when "red"
            material.color = Sketchup::Color.new(255, 0, 0)
          when "green"
            material.color = Sketchup::Color.new(0, 255, 0)
          when "blue"
            material.color = Sketchup::Color.new(0, 0, 255)
          when "yellow"
            material.color = Sketchup::Color.new(255, 255, 0)
          when "cyan", "turquoise"
            material.color = Sketchup::Color.new(0, 255, 255)
          when "magenta", "purple"
            material.color = Sketchup::Color.new(255, 0, 255)
          when "white"
            material.color = Sketchup::Color.new(255, 255, 255)
          when "black"
            material.color = Sketchup::Color.new(0, 0, 0)
          when "brown"
            material.color = Sketchup::Color.new(139, 69, 19)
          when "orange"
            material.color = Sketchup::Color.new(255, 165, 0)
          when "gray", "grey"
            material.color = Sketchup::Color.new(128, 128, 128)
          else
            # If it's a hex color code like "#FF0000"
            if material_name.start_with?("#") && material_name.length == 7
              begin
                r = material_name[1..2].to_i(16)
                g = material_name[3..4].to_i(16)
                b = material_name[5..6].to_i(16)
                material.color = Sketchup::Color.new(r, g, b)
              rescue
                # Default to a wood color if parsing fails
                material.color = Sketchup::Color.new(184, 134, 72)
              end
            else
              # Default to a wood color
              material.color = Sketchup::Color.new(184, 134, 72)
            end
          end
        end
        
        # Apply the material to the entity
        if entity.respond_to?(:material=)
          entity.material = material
        elsif entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
          # For groups and components, we need to apply to all faces
          entities = entity.is_a?(Sketchup::Group) ? entity.entities : entity.definition.entities
          entities.grep(Sketchup::Face).each { |face| face.material = material }
        end
        
        { success: true, id: entity.entityID }
      else
        raise "Entity not found"
      end
    end
    
    def boolean_operation(params)
      log "Performing boolean operation with params: #{params.inspect}"
      model = Sketchup.active_model
      
      # Get operation type
      operation_type = params["operation"]
      unless ["union", "difference", "intersection"].include?(operation_type)
        raise "Invalid boolean operation: #{operation_type}. Must be 'union', 'difference', or 'intersection'."
      end
      
      # Get target and tool entities
      target_id = params["target_id"].to_s.gsub('"', '')
      tool_id = params["tool_id"].to_s.gsub('"', '')
      
      log "Looking for target entity with ID: #{target_id}"
      target_entity = model.find_entity_by_id(target_id.to_i)
      
      log "Looking for tool entity with ID: #{tool_id}"
      tool_entity = model.find_entity_by_id(tool_id.to_i)
      
      unless target_entity && tool_entity
        missing = []
        missing << "target" unless target_entity
        missing << "tool" unless tool_entity
        raise "Entity not found: #{missing.join(', ')}"
      end
      
      # Ensure both entities are groups or component instances
      unless (target_entity.is_a?(Sketchup::Group) || target_entity.is_a?(Sketchup::ComponentInstance)) &&
             (tool_entity.is_a?(Sketchup::Group) || tool_entity.is_a?(Sketchup::ComponentInstance))
        raise "Boolean operations require groups or component instances"
      end
      
      # Create a new group to hold the result
      result_group = model.active_entities.add_group
      
      # Perform the boolean operation
      case operation_type
      when "union"
        log "Performing union operation"
        perform_union(target_entity, tool_entity, result_group)
      when "difference"
        log "Performing difference operation"
        perform_difference(target_entity, tool_entity, result_group)
      when "intersection"
        log "Performing intersection operation"
        perform_intersection(target_entity, tool_entity, result_group)
      end
      
      # Clean up original entities if requested
      if params["delete_originals"]
        target_entity.erase! if target_entity.valid?
        tool_entity.erase! if tool_entity.valid?
      end
      
      # Return the result
      { 
        success: true, 
        id: result_group.entityID
      }
    end
    
    # Helper method for solid boolean operations
    # Note: True solid boolean operations require the SketchUp Solid Tools extension
    # This helper provides a placeholder for where boolean logic would go
    def subtract_entities(target_entities, tool_entities, target_transform = IDENTITY, tool_transform = IDENTITY)
      # Solid boolean subtraction is not available in the core SketchUp API
      # The Solid Tools extension provides this functionality
      # For now, we just log that this would require Solid Tools
      log "Note: Boolean subtraction requires SketchUp Solid Tools extension"
    end

    def perform_union(target, tool, result_group)
      model = Sketchup.active_model

      # Create temporary copies of the target and tool
      target_copy = target.copy
      tool_copy = tool.copy

      # Get the transformation of each entity
      target_transform = target.transformation
      tool_transform = tool.transformation

      # Apply the transformations to the copies
      target_copy.transform!(target_transform)
      tool_copy.transform!(tool_transform)

      # Get the entities from the copies
      target_entities = target_copy.is_a?(Sketchup::Group) ? target_copy.entities : target_copy.definition.entities
      tool_entities = tool_copy.is_a?(Sketchup::Group) ? tool_copy.entities : tool_copy.definition.entities

      # Copy all entities from target to result
      target_entities.each do |entity|
        entity.copy(result_group.entities)
      end

      # Copy all entities from tool to result
      tool_entities.each do |entity|
        entity.copy(result_group.entities)
      end

      # Clean up temporary copies
      target_copy.erase!
      tool_copy.erase!

      # Note: outer_shell is not a standard SketchUp API method
      # Would need Solid Tools extension for true boolean operations
    end
    
    def perform_difference(target, tool, result_group)
      model = Sketchup.active_model
      entities = model.active_entities

      # Use SketchUp's native Solid Tools if available via subtract tool
      # Fallback: manual boolean using intersect and erase

      # Create temporary group containing both target and tool
      temp_group = entities.add_group

      # Copy target into temp group
      target_copy = target.copy
      target_copy.transform!(target.transformation)
      temp_group.entities.add_instance(target_copy.is_a?(Sketchup::Group) ? target_copy.entities.parent : target_copy.definition, target_copy.transformation)

      # Copy tool into temp group
      tool_copy = tool.copy
      tool_copy.transform!(tool.transformation)
      temp_tool = temp_group.entities.add_instance(tool_copy.is_a?(Sketchup::Group) ? tool_copy.entities.parent : tool_copy.definition, tool_copy.transformation)

      # Explode the instances to get raw geometry
      temp_group.explode

      # Get all the faces that were created
      all_faces = temp_group.entities.grep(Sketchup::Face)

      # Find faces that are inside the tool volume and erase them
      # This is a simplified approach - for true solid subtraction, use the Solid Tools extension

      # For now, copy the target to the result
      target_entities = target.is_a?(Sketchup::Group) ? target.entities : target.definition.entities
      target_entities.each do |entity|
        entity.copy(result_group.entities)
      end

      # Clean up
      target_copy.erase!
      tool_copy.erase!
      temp_group.erase! if temp_group.valid?
    end
    
    def perform_intersection(target, tool, result_group)
      model = Sketchup.active_model
      entities = model.active_entities

      # Simplified intersection - copy target faces to result
      # True solid intersection requires the Solid Tools extension

      target_entities = target.is_a?(Sketchup::Group) ? target.entities : target.definition.entities
      target_entities.each do |entity|
        if entity.is_a?(Sketchup::Face)
          entity.copy(result_group.entities)
        end
      end

      # For proper boolean intersection, users should install the Solid Tools extension
      # or use the native Tools > Solid Tools > Intersect menu
    end
    
    def chamfer_edges(params)
      log "Chamfering edges with params: #{params.inspect}"
      model = Sketchup.active_model
      
      # Get entity ID
      entity_id = params["entity_id"].to_s.gsub('"', '')
      log "Looking for entity with ID: #{entity_id}"
      
      entity = model.find_entity_by_id(entity_id.to_i)
      unless entity
        raise "Entity not found: #{entity_id}"
      end
      
      # Ensure entity is a group or component instance
      unless entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
        raise "Chamfer operation requires a group or component instance"
      end
      
      # Get the distance parameter
      distance = params["distance"] || 0.5
      
      # Get the entities collection
      entities = entity.is_a?(Sketchup::Group) ? entity.entities : entity.definition.entities
      
      # Find all edges in the entity
      edges = entities.grep(Sketchup::Edge)
      
      # If specific edges are provided, filter the edges
      if params["edge_indices"] && params["edge_indices"].is_a?(Array)
        edge_indices = params["edge_indices"]
        edges = edges.select.with_index { |_, i| edge_indices.include?(i) }
      end
      
      # Create a new group to hold the result
      result_group = model.active_entities.add_group
      
      # Copy all entities from the original to the result
      entities.each do |e|
        e.copy(result_group.entities)
      end
      
      # Get the edges in the result group
      result_edges = result_group.entities.grep(Sketchup::Edge)
      
      # If specific edges were provided, filter the result edges
      if params["edge_indices"] && params["edge_indices"].is_a?(Array)
        edge_indices = params["edge_indices"]
        result_edges = result_edges.select.with_index { |_, i| edge_indices.include?(i) }
      end
      
      # Perform the chamfer operation
      begin
        # Create a transformation for the chamfer
        chamfer_transform = Geom::Transformation.scaling(1.0 - distance)
        
        # For each edge, create a chamfer
        result_edges.each do |edge|
          # Get the faces connected to this edge
          faces = edge.faces
          next if faces.length < 2
          
          # Get the start and end points of the edge
          start_point = edge.start.position
          end_point = edge.end.position
          
          # Calculate the midpoint of the edge
          midpoint = Geom::Point3d.new(
            (start_point.x + end_point.x) / 2.0,
            (start_point.y + end_point.y) / 2.0,
            (start_point.z + end_point.z) / 2.0
          )
          
          # Create a chamfer by creating a new face
          # This is a simplified approach - in a real implementation,
          # you would need to handle various edge cases
          new_points = []
          
          # For each vertex of the edge
          [edge.start, edge.end].each do |vertex|
            # Get all edges connected to this vertex
            connected_edges = vertex.edges - [edge]
            
            # For each connected edge
            connected_edges.each do |connected_edge|
              # Get the other vertex of the connected edge
              other_vertex = (connected_edge.vertices - [vertex])[0]
              
              # Calculate a point along the connected edge
              direction = other_vertex.position - vertex.position
              new_point = vertex.position.offset(direction, distance)
              
              new_points << new_point
            end
          end
          
          # Create a new face using the new points
          if new_points.length >= 3
            result_group.entities.add_face(new_points)
          end
        end
        
        # Clean up the original entity if requested
        if params["delete_original"]
          entity.erase! if entity.valid?
        end
        
        # Return the result
        { 
          success: true, 
          id: result_group.entityID
        }
      rescue StandardError => e
        log "Error in chamfer_edges: #{e.message}"
        log e.backtrace.join("\n")
        
        # Clean up the result group if there was an error
        result_group.erase! if result_group.valid?
        
        raise
      end
    end
    
    def fillet_edges(params)
      log "Filleting edges with params: #{params.inspect}"
      model = Sketchup.active_model
      
      # Get entity ID
      entity_id = params["entity_id"].to_s.gsub('"', '')
      log "Looking for entity with ID: #{entity_id}"
      
      entity = model.find_entity_by_id(entity_id.to_i)
      unless entity
        raise "Entity not found: #{entity_id}"
      end
      
      # Ensure entity is a group or component instance
      unless entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
        raise "Fillet operation requires a group or component instance"
      end
      
      # Get the radius parameter
      radius = params["radius"] || 0.5
      
      # Get the number of segments for the fillet
      segments = params["segments"] || 8
      
      # Get the entities collection
      entities = entity.is_a?(Sketchup::Group) ? entity.entities : entity.definition.entities
      
      # Find all edges in the entity
      edges = entities.grep(Sketchup::Edge)
      
      # If specific edges are provided, filter the edges
      if params["edge_indices"] && params["edge_indices"].is_a?(Array)
        edge_indices = params["edge_indices"]
        edges = edges.select.with_index { |_, i| edge_indices.include?(i) }
      end
      
      # Create a new group to hold the result
      result_group = model.active_entities.add_group
      
      # Copy all entities from the original to the result
      entities.each do |e|
        e.copy(result_group.entities)
      end
      
      # Get the edges in the result group
      result_edges = result_group.entities.grep(Sketchup::Edge)
      
      # If specific edges were provided, filter the result edges
      if params["edge_indices"] && params["edge_indices"].is_a?(Array)
        edge_indices = params["edge_indices"]
        result_edges = result_edges.select.with_index { |_, i| edge_indices.include?(i) }
      end
      
      # Perform the fillet operation
      begin
        # For each edge, create a fillet
        result_edges.each do |edge|
          # Get the faces connected to this edge
          faces = edge.faces
          next if faces.length < 2
          
          # Get the start and end points of the edge
          start_point = edge.start.position
          end_point = edge.end.position
          
          # Calculate the midpoint of the edge
          midpoint = Geom::Point3d.new(
            (start_point.x + end_point.x) / 2.0,
            (start_point.y + end_point.y) / 2.0,
            (start_point.z + end_point.z) / 2.0
          )
          
          # Calculate the edge vector
          edge_vector = end_point - start_point
          edge_length = edge_vector.length
          
          # Create points for the fillet curve
          fillet_points = []
          
          # Create a series of points along a circular arc
          (0..segments).each do |i|
            angle = Math::PI * i / segments
            
            # Calculate the point on the arc
            x = midpoint.x + radius * Math.cos(angle)
            y = midpoint.y + radius * Math.sin(angle)
            z = midpoint.z
            
            fillet_points << Geom::Point3d.new(x, y, z)
          end
          
          # Create edges connecting the fillet points
          (0...fillet_points.length - 1).each do |i|
            result_group.entities.add_line(fillet_points[i], fillet_points[i+1])
          end
          
          # Create a face from the fillet points
          if fillet_points.length >= 3
            result_group.entities.add_face(fillet_points)
          end
        end
        
        # Clean up the original entity if requested
        if params["delete_original"]
          entity.erase! if entity.valid?
        end
        
        # Return the result
        { 
          success: true, 
          id: result_group.entityID
        }
      rescue StandardError => e
        log "Error in fillet_edges: #{e.message}"
        log e.backtrace.join("\n")
        
        # Clean up the result group if there was an error
        result_group.erase! if result_group.valid?
        
        raise
      end
    end
    
    def create_mortise_tenon(params)
      log "Creating mortise and tenon joint with params: #{params.inspect}"
      model = Sketchup.active_model
      
      # Get the mortise and tenon board IDs
      mortise_id = params["mortise_id"].to_s.gsub('"', '')
      tenon_id = params["tenon_id"].to_s.gsub('"', '')
      
      log "Looking for mortise board with ID: #{mortise_id}"
      mortise_board = model.find_entity_by_id(mortise_id.to_i)
      
      log "Looking for tenon board with ID: #{tenon_id}"
      tenon_board = model.find_entity_by_id(tenon_id.to_i)
      
      unless mortise_board && tenon_board
        missing = []
        missing << "mortise board" unless mortise_board
        missing << "tenon board" unless tenon_board
        raise "Entity not found: #{missing.join(', ')}"
      end
      
      # Ensure both entities are groups or component instances
      unless (mortise_board.is_a?(Sketchup::Group) || mortise_board.is_a?(Sketchup::ComponentInstance)) &&
             (tenon_board.is_a?(Sketchup::Group) || tenon_board.is_a?(Sketchup::ComponentInstance))
        raise "Mortise and tenon operation requires groups or component instances"
      end
      
      # Get joint parameters
      width = params["width"] || 1.0
      height = params["height"] || 1.0
      depth = params["depth"] || 1.0
      offset_x = params["offset_x"] || 0.0
      offset_y = params["offset_y"] || 0.0
      offset_z = params["offset_z"] || 0.0
      
      # Get the bounds of both boards
      mortise_bounds = mortise_board.bounds
      tenon_bounds = tenon_board.bounds
      
      # Determine the face to place the joint on based on the relative positions of the boards
      mortise_center = mortise_bounds.center
      tenon_center = tenon_bounds.center
      
      # Calculate the direction vector from mortise to tenon
      direction_vector = tenon_center - mortise_center
      
      # Determine which face of the mortise board is closest to the tenon board
      mortise_face_direction = determine_closest_face(direction_vector)
      
      # Create the mortise (hole) in the mortise board
      mortise_group = create_mortise(
        mortise_board,
        width,
        height,
        depth,
        mortise_face_direction,
        mortise_bounds,
        offset_x,
        offset_y,
        offset_z
      )

      # Determine which face of the tenon board is closest to the mortise board
      tenon_face_direction = determine_closest_face(direction_vector.reverse)

      # Create the tenon (projection) on the tenon board
      tenon_group = create_tenon(
        tenon_board,
        width,
        height,
        depth,
        tenon_face_direction,
        tenon_bounds,
        offset_x,
        offset_y,
        offset_z
      )

      # Return the result
      {
        success: true,
        message: "Mortise and tenon geometry created. Use Solid Tools > Subtract to cut the mortise, and Solid Tools > Union to attach the tenon.",
        mortise_group_id: mortise_group&.entityID,
        tenon_group_id: tenon_group&.entityID
      }
    end
    
    def determine_closest_face(direction_vector)
      # Normalize the direction vector
      direction_vector.normalize!
      
      # Determine which axis has the largest component
      x_abs = direction_vector.x.abs
      y_abs = direction_vector.y.abs
      z_abs = direction_vector.z.abs
      
      if x_abs >= y_abs && x_abs >= z_abs
        # X-axis is dominant
        return direction_vector.x > 0 ? :east : :west
      elsif y_abs >= x_abs && y_abs >= z_abs
        # Y-axis is dominant
        return direction_vector.y > 0 ? :north : :south
      else
        # Z-axis is dominant
        return direction_vector.z > 0 ? :top : :bottom
      end
    end
    
    def create_mortise(board, width, height, depth, face_direction, bounds, offset_x, offset_y, offset_z)
      model = Sketchup.active_model
      entities = model.active_entities

      # Calculate the position of the mortise based on the face direction
      mortise_position = calculate_position_on_face(face_direction, bounds, width, height, depth, offset_x, offset_y, offset_z)

      log "Creating mortise at position: #{mortise_position.inspect} with dimensions: #{[width, height, depth].inspect}"

      # Create a group for the mortise (cutout guide)
      mortise_group = entities.add_group
      mortise_group.name = "Mortise (Cutout Guide)"

      # Create the mortise box with the correct orientation
      case face_direction
      when :east, :west
        # Mortise on east or west face (YZ plane)
        mortise_face = mortise_group.entities.add_face(
          [mortise_position[0], mortise_position[1], mortise_position[2]],
          [mortise_position[0], mortise_position[1] + width, mortise_position[2]],
          [mortise_position[0], mortise_position[1] + width, mortise_position[2] + height],
          [mortise_position[0], mortise_position[1], mortise_position[2] + height]
        )
        mortise_face.pushpull(face_direction == :east ? -depth : depth) if mortise_face
      when :north, :south
        # Mortise on north or south face (XZ plane)
        mortise_face = mortise_group.entities.add_face(
          [mortise_position[0], mortise_position[1], mortise_position[2]],
          [mortise_position[0] + width, mortise_position[1], mortise_position[2]],
          [mortise_position[0] + width, mortise_position[1], mortise_position[2] + height],
          [mortise_position[0], mortise_position[1], mortise_position[2] + height]
        )
        mortise_face.pushpull(face_direction == :north ? -depth : depth) if mortise_face
      when :top, :bottom
        # Mortise on top or bottom face (XY plane)
        mortise_face = mortise_group.entities.add_face(
          [mortise_position[0], mortise_position[1], mortise_position[2]],
          [mortise_position[0] + width, mortise_position[1], mortise_position[2]],
          [mortise_position[0] + width, mortise_position[1] + height, mortise_position[2]],
          [mortise_position[0], mortise_position[1] + height, mortise_position[2]]
        )
        mortise_face.pushpull(face_direction == :top ? -depth : depth) if mortise_face
      end

      mortise_group
    end
    
    def create_tenon(board, width, height, depth, face_direction, bounds, offset_x, offset_y, offset_z)
      model = Sketchup.active_model
      entities = model.active_entities

      # Calculate the position of the tenon based on the face direction
      tenon_position = calculate_position_on_face(face_direction, bounds, width, height, depth, offset_x, offset_y, offset_z)

      log "Creating tenon at position: #{tenon_position.inspect} with dimensions: #{[width, height, depth].inspect}"

      # Create a group for the tenon
      tenon_group = entities.add_group
      tenon_group.name = "Tenon"

      # Create the tenon box with the correct orientation
      case face_direction
      when :east, :west
        # Tenon on east or west face (YZ plane)
        tenon_face = tenon_group.entities.add_face(
          [tenon_position[0], tenon_position[1], tenon_position[2]],
          [tenon_position[0], tenon_position[1] + width, tenon_position[2]],
          [tenon_position[0], tenon_position[1] + width, tenon_position[2] + height],
          [tenon_position[0], tenon_position[1], tenon_position[2] + height]
        )
        tenon_face.pushpull(face_direction == :east ? depth : -depth) if tenon_face
      when :north, :south
        # Tenon on north or south face (XZ plane)
        tenon_face = tenon_group.entities.add_face(
          [tenon_position[0], tenon_position[1], tenon_position[2]],
          [tenon_position[0] + width, tenon_position[1], tenon_position[2]],
          [tenon_position[0] + width, tenon_position[1], tenon_position[2] + height],
          [tenon_position[0], tenon_position[1], tenon_position[2] + height]
        )
        tenon_face.pushpull(face_direction == :north ? depth : -depth) if tenon_face
      when :top, :bottom
        # Tenon on top or bottom face (XY plane)
        tenon_face = tenon_group.entities.add_face(
          [tenon_position[0], tenon_position[1], tenon_position[2]],
          [tenon_position[0] + width, tenon_position[1], tenon_position[2]],
          [tenon_position[0] + width, tenon_position[1] + height, tenon_position[2]],
          [tenon_position[0], tenon_position[1] + height, tenon_position[2]]
        )
        tenon_face.pushpull(face_direction == :top ? depth : -depth) if tenon_face
      end

      tenon_group
    end
    
    def calculate_position_on_face(face_direction, bounds, width, height, depth, offset_x, offset_y, offset_z)
      # Calculate the position on the specified face with offsets
      case face_direction
      when :east
        # Position on the east face (max X)
        [
          bounds.max.x,
          bounds.center.y - width/2 + offset_y,
          bounds.center.z - height/2 + offset_z
        ]
      when :west
        # Position on the west face (min X)
        [
          bounds.min.x,
          bounds.center.y - width/2 + offset_y,
          bounds.center.z - height/2 + offset_z
        ]
      when :north
        # Position on the north face (max Y)
        [
          bounds.center.x - width/2 + offset_x,
          bounds.max.y,
          bounds.center.z - height/2 + offset_z
        ]
      when :south
        # Position on the south face (min Y)
        [
          bounds.center.x - width/2 + offset_x,
          bounds.min.y,
          bounds.center.z - height/2 + offset_z
        ]
      when :top
        # Position on the top face (max Z)
        [
          bounds.center.x - width/2 + offset_x,
          bounds.center.y - height/2 + offset_y,
          bounds.max.z
        ]
      when :bottom
        # Position on the bottom face (min Z)
        [
          bounds.center.x - width/2 + offset_x,
          bounds.center.y - height/2 + offset_y,
          bounds.min.z
        ]
      end
    end
    
    def create_dovetail(params)
      log "Creating dovetail joint with params: #{params.inspect}"
      model = Sketchup.active_model
      
      # Get the tail and pin board IDs
      tail_id = params["tail_id"].to_s.gsub('"', '')
      pin_id = params["pin_id"].to_s.gsub('"', '')
      
      log "Looking for tail board with ID: #{tail_id}"
      tail_board = model.find_entity_by_id(tail_id.to_i)
      
      log "Looking for pin board with ID: #{pin_id}"
      pin_board = model.find_entity_by_id(pin_id.to_i)
      
      unless tail_board && pin_board
        missing = []
        missing << "tail board" unless tail_board
        missing << "pin board" unless pin_board
        raise "Entity not found: #{missing.join(', ')}"
      end
      
      # Ensure both entities are groups or component instances
      unless (tail_board.is_a?(Sketchup::Group) || tail_board.is_a?(Sketchup::ComponentInstance)) &&
             (pin_board.is_a?(Sketchup::Group) || pin_board.is_a?(Sketchup::ComponentInstance))
        raise "Dovetail operation requires groups or component instances"
      end
      
      # Get joint parameters
      width = params["width"] || 1.0
      height = params["height"] || 2.0
      depth = params["depth"] || 1.0
      angle = params["angle"] || 15.0  # Dovetail angle in degrees
      num_tails = params["num_tails"] || 3
      offset_x = params["offset_x"] || 0.0
      offset_y = params["offset_y"] || 0.0
      offset_z = params["offset_z"] || 0.0
      
      # Create the tails on the tail board
      tails_group = create_tails(tail_board, width, height, depth, angle, num_tails, offset_x, offset_y, offset_z)

      # Create the pins on the pin board
      pins_group = create_pins(pin_board, width, height, depth, angle, num_tails, offset_x, offset_y, offset_z)

      # Return the result
      {
        success: true,
        message: "Dovetail geometry created. Use Solid Tools to cut the pins and tails.",
        tails_group_id: tails_group&.entityID,
        pins_group_id: pins_group&.entityID
      }
    end
    
    def create_tails(board, width, height, depth, angle, num_tails, offset_x, offset_y, offset_z)
      model = Sketchup.active_model
      entities = model.active_entities

      # Get the board's bounds
      bounds = board.bounds

      # Calculate the position of the dovetail joint
      center_x = bounds.center.x + offset_x
      center_y = bounds.center.y + offset_y
      center_z = bounds.center.z + offset_z

      # Calculate the width of each tail and space
      total_width = width
      tail_width = total_width / (2 * num_tails - 1)

      # Create a group for the tails
      tails_group = entities.add_group
      tails_group.name = "Dovetail Tails"

      # Create each tail
      num_tails.times do |i|
        # Calculate the position of this tail
        tail_center_x = center_x - width/2 + tail_width * (2 * i)

        # Calculate the dovetail shape
        angle_rad = angle * Math::PI / 180.0
        tail_top_width = tail_width
        tail_bottom_width = tail_width + 2 * depth * Math.tan(angle_rad)

        # Create the tail shape
        tail_points = [
          [tail_center_x - tail_top_width/2, center_y - height/2, center_z],
          [tail_center_x + tail_top_width/2, center_y - height/2, center_z],
          [tail_center_x + tail_bottom_width/2, center_y - height/2, center_z - depth],
          [tail_center_x - tail_bottom_width/2, center_y - height/2, center_z - depth]
        ]

        # Create the tail face
        tail_face = tails_group.entities.add_face(tail_points)

        # Extrude the tail
        tail_face.pushpull(height) if tail_face
      end

      tails_group
    end
    
    def create_pins(board, width, height, depth, angle, num_tails, offset_x, offset_y, offset_z)
      model = Sketchup.active_model
      entities = model.active_entities

      # Get the board's bounds
      bounds = board.bounds

      # Calculate the position of the dovetail joint
      center_x = bounds.center.x + offset_x
      center_y = bounds.center.y + offset_y
      center_z = bounds.center.z + offset_z

      # Calculate the width of each tail and space
      total_width = width
      tail_width = total_width / (2 * num_tails - 1)

      # Create a group for the pins (cutout guide)
      pins_group = entities.add_group
      pins_group.name = "Dovetail Pins (Cutout Guide)"

      # Create each pin shape (these form the cutout geometry)
      num_tails.times do |i|
        # Calculate the position of this pin
        pin_center_x = center_x - width/2 + tail_width * (2 * i)

        # Calculate the dovetail shape (inverse of tails - these get cut out)
        angle_rad = angle * Math::PI / 180.0
        pin_top_width = tail_width + 2 * depth * Math.tan(angle_rad)
        pin_bottom_width = tail_width

        # Create the pin shape
        pin_points = [
          [pin_center_x - pin_top_width/2, center_y - height/2, center_z],
          [pin_center_x + pin_top_width/2, center_y - height/2, center_z],
          [pin_center_x + pin_bottom_width/2, center_y - height/2, center_z - depth],
          [pin_center_x - pin_bottom_width/2, center_y - height/2, center_z - depth]
        ]

        # Create the pin face
        pin_face = pins_group.entities.add_face(pin_points)

        # Extrude the pin
        pin_face.pushpull(height) if pin_face
      end

      pins_group
    end
    
    def create_finger_joint(params)
      log "Creating finger joint with params: #{params.inspect}"
      model = Sketchup.active_model

      # Get the two board IDs
      board1_id = params["board1_id"].to_s.gsub('"', '')
      board2_id = params["board2_id"].to_s.gsub('"', '')

      log "Looking for board 1 with ID: #{board1_id}"
      board1 = model.find_entity_by_id(board1_id.to_i)

      log "Looking for board 2 with ID: #{board2_id}"
      board2 = model.find_entity_by_id(board2_id.to_i)

      unless board1 && board2
        missing = []
        missing << "board 1" unless board1
        missing << "board 2" unless board2
        raise "Entity not found: #{missing.join(', ')}"
      end

      # Ensure both entities are groups or component instances
      unless (board1.is_a?(Sketchup::Group) || board1.is_a?(Sketchup::ComponentInstance)) &&
             (board2.is_a?(Sketchup::Group) || board2.is_a?(Sketchup::ComponentInstance))
        raise "Finger joint operation requires groups or component instances"
      end

      # Get joint parameters
      width = params["width"] || 1.0
      height = params["height"] || 2.0
      depth = params["depth"] || 1.0
      num_fingers = params["num_fingers"] || 5
      offset_x = params["offset_x"] || 0.0
      offset_y = params["offset_y"] || 0.0
      offset_z = params["offset_z"] || 0.0

      # Create the fingers on board 1 as a new group
      fingers_group = create_fingers_geometry(board1, width, height, depth, num_fingers, offset_x, offset_y, offset_z)

      # Create the matching slots on board 2 as cutout guides
      slots_group = create_slots_geometry(board2, width, height, depth, num_fingers, offset_x, offset_y, offset_z)

      # Return the result
      {
        success: true,
        message: "Finger joint geometry created. Use Solid Tools > Subtract to cut the slots from board 2.",
        fingers_group_id: fingers_group&.entityID,
        slots_group_id: slots_group&.entityID
      }
    end
    
    def create_fingers_geometry(board, width, height, depth, num_fingers, offset_x, offset_y, offset_z)
      model = Sketchup.active_model
      entities = model.active_entities

      # Get the board's bounds
      bounds = board.bounds

      # Calculate the position of the joint
      center_x = bounds.center.x + offset_x
      center_y = bounds.center.y + offset_y
      center_z = bounds.center.z + offset_z

      # Calculate the width of each finger
      finger_width = width / num_fingers

      # Create a group for the fingers
      fingers_group = entities.add_group
      fingers_group.name = "Finger Joint - Fingers"

      # Create individual finger boxes
      (num_fingers / 2 + num_fingers % 2).times do |i|
        finger_center_x = center_x - width/2 + finger_width * (2 * i)

        # Create a box for this finger
        face = fingers_group.entities.add_face(
          [finger_center_x - finger_width/2, center_y - height/2, center_z],
          [finger_center_x + finger_width/2, center_y - height/2, center_z],
          [finger_center_x + finger_width/2, center_y + height/2, center_z],
          [finger_center_x - finger_width/2, center_y + height/2, center_z]
        )
        face.pushpull(depth) if face
      end

      fingers_group
    end

    def create_slots_geometry(board, width, height, depth, num_fingers, offset_x, offset_y, offset_z)
      model = Sketchup.active_model
      entities = model.active_entities

      # Get the board's bounds
      bounds = board.bounds

      # Calculate the position of the joint
      center_x = bounds.center.x + offset_x
      center_y = bounds.center.y + offset_y
      center_z = bounds.center.z + offset_z

      # Calculate the width of each finger
      finger_width = width / num_fingers

      # Create a group for the slots (cutout guides)
      slots_group = entities.add_group
      slots_group.name = "Finger Joint - Slots (Cutout Guide)"

      # Create slot cutout boxes
      (num_fingers / 2).times do |i|
        slot_center_x = center_x - width/2 + finger_width * (2 * i + 1)

        # Create a box for this slot
        face = slots_group.entities.add_face(
          [slot_center_x - finger_width/2, center_y - height/2, center_z],
          [slot_center_x + finger_width/2, center_y - height/2, center_z],
          [slot_center_x + finger_width/2, center_y + height/2, center_z],
          [slot_center_x - finger_width/2, center_y + height/2, center_z]
        )
        face.pushpull(depth) if face
      end

      slots_group
    end
    
    def eval_ruby(params)
      log "Evaluating Ruby code with length: #{params['code'].length}"
      
      begin
        # Create a safe binding for evaluation
        binding = TOPLEVEL_BINDING.dup
        
        # Evaluate the Ruby code
        log "Starting code evaluation..."
        result = eval(params["code"], binding)
        log "Code evaluation completed with result: #{result.inspect}"
        
        # Return success with the result as a string
        { 
          success: true,
          result: result.to_s
        }
      rescue StandardError => e
        log "Error in eval_ruby: #{e.message}"
        log e.backtrace.join("\n")
        raise "Ruby evaluation error: #{e.message}"
      end
    end
    
    # =============================================================================
    # Screenshot Tool
    # =============================================================================
    
    def take_screenshot(params)
      log "Taking screenshot with params: #{params.inspect}"
      
      begin
        model = Sketchup.active_model
        view = model.active_view
        
        # Get parameters with defaults
        width = params["width"] || 1920
        height = params["height"] || 1080
        file_format = params["format"] || params["file_format"] || "png"
        transparent = params["transparent"] || false
        antialias = params["antialias"].nil? ? true : params["antialias"]
        
        # Determine save path
        if params["save_path"]
          save_dir = params["save_path"]
          FileUtils.mkdir_p(save_dir) unless Dir.exist?(save_dir)
        else
          save_dir = File.join(ENV['TEMP'] || ENV['TMP'] || Dir.home, "sketchup_screenshots")
          FileUtils.mkdir_p(save_dir) unless Dir.exist?(save_dir)
        end
        
        # Generate filename
        if params["filename"]
          base_name = params["filename"]
        else
          timestamp = Time.now.strftime("%Y%m%d_%H%M%S")
          base_name = "sketchup_screenshot_#{timestamp}"
        end
        
        # Determine extension and format
        ext = file_format.downcase == "jpg" ? "jpg" : "png"
        full_path = File.join(save_dir, "#{base_name}.#{ext}")
        
        # Export the image
        options = {
          :filename => full_path,
          :width => width,
          :height => height,
          :antialias => antialias
        }
        
        # Only PNG supports transparency
        if ext == "png"
          options[:transparent] = transparent
        end
        
        log "Exporting screenshot to: #{full_path}"
        success = view.write_image(options)
        
        if success
          log "Screenshot saved successfully"
          {
            success: true,
            path: full_path,
            filename: "#{base_name}.#{ext}",
            dimensions: [width, height],
            format: ext
          }
        else
          raise "Failed to write screenshot image"
        end
        
      rescue StandardError => e
        log "Error in take_screenshot: #{e.message}"
        log e.backtrace.join("\n")
        raise
      end
    end
    
    # =============================================================================
    # UrbanA Development Tools
    # =============================================================================
    
    def get_buildings(params)
      log "Getting buildings with params: #{params.inspect}"
      
      begin
        # Check if UrbanA is loaded
        unless defined?(UrbanA) && UrbanA.const_defined?(:Core)
          return {
            success: false,
            error: "UrbanA extension not loaded",
            buildings: [],
            count: 0
          }
        end
        
        state = UrbanA::Core.state rescue nil
        unless state
          return {
            success: true,
            buildings: [],
            count: 0,
            note: "UrbanA state not initialized"
          }
        end
        
        su2ua_buildings = state.su2ua_buildings || {}
        selected_paths = state.selected_buildings || []
        
        # Convert to array for JSON serialization
        buildings = []
        su2ua_buildings.each do |path, ua_building|
          # Skip if filtering by selection
          if params["filter_selected"] && !selected_paths.include?(path)
            next
          end
          
          building_info = {
            path_key: path_to_string(path),
            entity_id: (path.last.entityID rescue nil),
            entity_name: (path.last.name rescue nil),
            typename: (path.last.typename rescue nil)
          }

          if params["include_details"] && ua_building
            # Add UrbanA building details
            building_info[:land_use] = (ua_building.land_use rescue nil)
            building_info[:building_id] = (ua_building.building_id rescue nil)
            
            # Add UCVs if available
            if ua_building.respond_to?(:ucvs)
              ucvs = {}
              ua_building.ucvs.each do |key, ucvs_obj|
                begin
                  ucvs[key] = {
                    external_value: ucvs_obj.external_value,
                    internal_value: ucvs_obj.internal_value,
                    unit: ucvs_obj.unit
                  }
                rescue
                  # Skip if UCV can't be read
                end
              end rescue nil
              building_info[:ucvs] = ucvs unless ucvs.empty?
            end
            
            # Add parameters if available
            if ua_building.respond_to?(:parameters)
              params_hash = {}
              ua_building.parameters.each do |key, param|
                begin
                  params_hash[key] = {
                    value: param.value,
                    unit: param.unit
                  }
                rescue
                  # Skip if parameter can't be read
                end
              end rescue nil
              building_info[:parameters] = params_hash unless params_hash.empty?
            end
            
            # Add storeys info
            if ua_building.respond_to?(:building_storeys) && ua_building.building_storeys
              building_info[:storeys] = (ua_building.building_storeys.storeys rescue nil)
            end
          end
          
          buildings << building_info
        end
        
        {
          success: true,
          count: buildings.length,
          buildings: buildings,
          selected_count: selected_paths.length,
          urbanA_loaded: true
        }
        
      rescue StandardError => e
        log "Error in get_buildings: #{e.message}"
        log e.backtrace.join("\n")
        {
          success: false,
          error: e.message,
          buildings: [],
          count: 0
        }
      end
    end
    
    def get_urbanA_state_summary(params)
      log "Getting UrbanA state summary"
      
      begin
        # Check if UrbanA is loaded
        unless defined?(UrbanA) && UrbanA.const_defined?(:Core)
          return {
            success: true,
            urbanA_loaded: false,
            message: "UrbanA extension not loaded"
          }
        end
        
        state = UrbanA::Core.state rescue nil
        unless state
          return {
            success: true,
            urbanA_loaded: true,
            state_initialized: false,
            message: "UrbanA loaded but state not initialized"
          }
        end
        
        # Gather state summary
        summary = {
          success: true,
          urbanA_loaded: true,
          state_initialized: true,
          building_count: state.su2ua_buildings ? state.su2ua_buildings.size : 0,
          block_count: state.su2ua_blocks ? state.su2ua_blocks.size : 0,
          selected_buildings_count: state.selected_buildings ? state.selected_buildings.length : 0,
          selected_blocks_count: state.selected_blocks ? state.selected_blocks.length : 0,
          selected_segments_count: state.selected_segments ? state.selected_segments.length : 0,
          selected_nodes_count: state.selected_nodes ? state.selected_nodes.length : 0,
          land_use_count: state.land_uses ? state.land_uses.size : 0,
          street_type_count: state.street_types ? state.street_types.size : 0
        }
        
        # Add project info if available
        if state.project
          begin
            summary[:project] = {
              name: state.project.name,
              description: state.project.description,
              total_buildings: state.project.buildings ? state.project.buildings.length : 0
            }
          rescue
            # Skip if project info can't be read
          end
        end
        
        # Add current tool if available
        if state.respond_to?(:current_tool)
          summary[:current_tool] = state.current_tool.class.name rescue nil
        end
        
        summary
        
      rescue StandardError => e
        log "Error in get_urbanA_state_summary: #{e.message}"
        log e.backtrace.join("\n")
        {
          success: false,
          error: e.message,
          urbanA_loaded: defined?(UrbanA) && UrbanA.const_defined?(:Core)
        }
      end
    end
    
    def get_selected_buildings(params)
      log "Getting selected buildings"
      
      begin
        # Check if UrbanA is loaded
        unless defined?(UrbanA) && UrbanA.const_defined?(:Core)
          return {
            success: false,
            error: "UrbanA extension not loaded",
            selected_buildings: []
          }
        end
        
        state = UrbanA::Core.state rescue nil
        unless state
          return {
            success: true,
            selected_buildings: [],
            count: 0,
            note: "UrbanA state not initialized"
          }
        end
        
        su2ua_buildings = state.su2ua_buildings || {}
        selected_paths = state.selected_buildings || []
        
        selected_buildings = []
        selected_paths.each do |path|
          ua_building = su2ua_buildings[path]
          next unless ua_building
          
          entity = path.last
          building_info = {
            path_key: path_to_string(path),
            entity_id: (entity.entityID rescue nil),
            entity_name: (entity.name rescue nil),
            typename: (entity.typename rescue nil),
            land_use: (ua_building.land_use rescue nil)
          }
          
          # Add UCV summary
          if ua_building.respond_to?(:ucvs)
            begin
              gfa = ua_building.ucvs[:UCV_gross_floor_area]
              if gfa
                building_info[:gross_floor_area] = {
                  value: gfa.external_value,
                  unit: gfa.unit
                }
              end
            rescue
            end
          end
          
          selected_buildings << building_info
        end
        
        {
          success: true,
          count: selected_buildings.length,
          selected_buildings: selected_buildings
        }
        
      rescue StandardError => e
        log "Error in get_selected_buildings: #{e.message}"
        log e.backtrace.join("\n")
        {
          success: false,
          error: e.message,
          selected_buildings: []
        }
      end
    end
    
    def get_entity_info(params)
      log "Getting entity info with params: #{params.inspect}"
      
      begin
        model = Sketchup.active_model
        entity = nil
        
        # Find by ID if provided
        if params["entity_id"]
          entity_id = params["entity_id"].to_s.gsub('"', '').to_i
          entity = model.find_entity_by_id(entity_id)
        end
        
        # Find by name if provided and no entity found by ID
        if entity.nil? && params["entity_name"]
          entity_name = params["entity_name"]
          # Search in all entities
          model.entities.each do |ent|
            if ent.respond_to?(:name) && ent.name == entity_name
              entity = ent
              break
            end
          end
        end
        
        unless entity
          return {
            success: false,
            error: "Entity not found"
          }
        end
        
        # Build entity info
        info = {
          entityID: entity.entityID,
          typename: entity.typename,
          valid: entity.valid?,
          deleted: entity.deleted?,
          bounds: {
            min: [entity.bounds.min.x, entity.bounds.min.y, entity.bounds.min.z],
            max: [entity.bounds.max.x, entity.bounds.max.y, entity.bounds.max.z],
            center: [entity.bounds.center.x, entity.bounds.center.y, entity.bounds.center.z],
            width: entity.bounds.width,
            height: entity.bounds.height,
            depth: entity.bounds.depth
          }
        }
        
        # Add name if available
        if entity.respond_to?(:name)
          info[:name] = entity.name
        end
        
        # Add layer info if available
        if entity.respond_to?(:layer)
          info[:layer] = entity.layer.name rescue nil
        end
        
        # Add material info if available
        if entity.respond_to?(:material) && entity.material
          info[:material] = entity.material.name
        end
        
        # Check if tracked by UrbanA
        if defined?(UrbanA) && UrbanA.const_defined?(:Core)
          begin
            state = UrbanA::Core.state
            if state && state.su2ua_buildings
              # Check if this entity is in any building path
              is_tracked = false
              tracked_info = nil
              
              state.su2ua_buildings.each do |path, ua_building|
                if path.last == entity
                  is_tracked = true
                  tracked_info = {
                    land_use: (ua_building.land_use rescue nil),
                    building_id: (ua_building.building_id rescue nil)
                  }
                  break
                end
              end
              
              info[:urbanA_tracked] = is_tracked
              info[:urbanA_info] = tracked_info if tracked_info
            end
          rescue
            # Ignore UrbanA errors
          end
        end
        
        # Add component/group specific info
        if entity.is_a?(Sketchup::ComponentInstance) || entity.is_a?(Sketchup::Group)
          if entity.is_a?(Sketchup::ComponentInstance)
            info[:definition_name] = entity.definition.name
            info[:definition_count] = entity.definition.count_instances
          end
          info[:transformation] = {
            origin: [
              entity.transformation.origin.x,
              entity.transformation.origin.y,
              entity.transformation.origin.z
            ]
          }
        end
        
        {
          success: true,
          entity: info
        }
        
      rescue StandardError => e
        log "Error in get_entity_info: #{e.message}"
        log e.backtrace.join("\n")
        {
          success: false,
          error: e.message
        }
      end
    end
    
    def refresh_urbanA(params)
      log "Refreshing UrbanA state"

      begin
        # Check if UrbanA is loaded
        unless defined?(UrbanA) && UrbanA.const_defined?(:Core)
          return {
            success: false,
            error: "UrbanA extension not loaded"
          }
        end

        # Try to trigger a refresh of the UrbanA state
        # This typically involves re-scanning the model
        state = UrbanA::Core.state rescue nil

        if state
          # Try to find and call the sync or refresh method
          if state.respond_to?(:sync_from_model)
            state.sync_from_model
            log "Called sync_from_model"
          elsif state.respond_to?(:refresh)
            state.refresh
            log "Called refresh"
          elsif state.respond_to?(:update_selection)
            # Trigger selection update to refresh state
            state.update_selection
            log "Called update_selection"
          end

          # Return updated counts
          {
            success: true,
            message: "UrbanA state refreshed",
            building_count: state.su2ua_buildings ? state.su2ua_buildings.size : 0,
            block_count: state.su2ua_blocks ? state.su2ua_blocks.size : 0
          }
        else
          {
            success: false,
            error: "UrbanA state not initialized"
          }
        end

      rescue StandardError => e
        log "Error in refresh_urbanA: #{e.message}"
        log e.backtrace.join("\n")
        {
          success: false,
          error: e.message
        }
      end
    end

    def set_building_land_use(params)
      log "Setting building land use with params: #{params.inspect}"

      begin
        entity_id = params["entity_id"]
        new_land_use = params["land_use"]

        unless entity_id && new_land_use
          return {
            success: false,
            error: "Missing required parameters: entity_id and land_use"
          }
        end

        # Check if UrbanA is loaded
        unless defined?(UrbanA) && UrbanA.const_defined?(:Core)
          return {
            success: false,
            error: "UrbanA extension not loaded"
          }
        end

        state = UrbanA::Core.state rescue nil
        unless state
          return {
            success: false,
            error: "UrbanA state not initialized"
          }
        end

        # Find the building by entity ID
        model = Sketchup.active_model
        entity = model.find_entity_by_id(entity_id.to_i)

        unless entity
          return {
            success: false,
            error: "Entity not found with ID: #{entity_id}"
          }
        end

        # Find the UrbanA building for this entity
        su2ua_buildings = state.su2ua_buildings || {}
        ua_building = nil
        building_path = nil

        su2ua_buildings.each do |path, building|
          if path.last == entity
            ua_building = building
            building_path = path
            break
          end
        end

        unless ua_building
          return {
            success: false,
            error: "Entity #{entity_id} is not tracked by UrbanA as a building"
          }
        end

        # Try to set the land use - wrap in operation for safety
        if ua_building.respond_to?(:land_use=)
          model = Sketchup.active_model
          old_land_use = ua_building.land_use

          # Start an operation for the land use change
          model.start_operation("Set Land Use", true)
          begin
            ua_building.land_use = new_land_use

            # Try to trigger recalculation if available
            if ua_building.respond_to?(:recalculate)
              ua_building.recalculate
            elsif ua_building.respond_to?(:update_ucvs)
              ua_building.update_ucvs
            end

            model.commit_operation

            {
              success: true,
              message: "Land use updated",
              entity_id: entity_id,
              old_land_use: old_land_use,
              new_land_use: new_land_use
            }
          rescue => e
            model.abort_operation
            raise e
          end
        else
          {
            success: false,
            error: "Building object does not support setting land_use"
          }
        end

      rescue StandardError => e
        log "Error in set_building_land_use: #{e.message}"
        log e.backtrace.join("\n")
        {
          success: false,
          error: e.message
        }
      end
    end

    # Helper method to convert entity path to string for JSON serialization
    def path_to_string(path)
      return "nil" unless path
      return "empty" if path.empty?
      
      path.map { |e| 
        begin
          "#{e.typename}##{e.entityID}(#{e.name || 'unnamed'})"
        rescue
          "unknown"
        end
      }.join(" -> ")
    end

    # ============================================================================
    # Operation Management
    # ============================================================================

    def start_operation(params)
      name = params["name"] || "MCP Operation"
      transparent = params["transparent"] || false

      model = Sketchup.active_model
      log "Starting operation: #{name}, transparent=#{transparent}"

      success = model.start_operation(name, transparent)

      if success
        { success: true, result: "Operation '#{name}' started" }
      else
        { success: false, result: "Failed to start operation" }
      end
    end

    def commit_operation(params)
      model = Sketchup.active_model
      log "Committing operation"

      success = model.commit_operation

      if success
        { success: true, result: "Operation committed successfully" }
      else
        { success: false, result: "No active operation to commit" }
      end
    end

    def abort_operation(params)
      model = Sketchup.active_model
      log "Aborting operation"

      success = model.abort_operation

      if success
        { success: true, result: "Operation aborted, changes reverted" }
      else
        { success: false, result: "No active operation to abort" }
      end
    end

    def undo(params)
      count = params["count"] || 1
      log "Undoing #{count} operation(s)"

      count.times do |i|
        # Use Sketchup.undo instead of model.undo
        Sketchup.undo
        log "Undo step #{i + 1}"
      end

      { success: true, result: "Undone #{count} operation(s)" }
    end

    def redo_operation(params)
      count = params["count"] || 1
      log "Redoing #{count} operation(s)"

      count.times do |i|
        # Use Sketchup.redo instead of model.redo
        Sketchup.redo
        log "Redo step #{i + 1}"
      end

      { success: true, result: "Redone #{count} operation(s)" }
    end

    # ============================================================================
    # Selection Tools
    # ============================================================================

    def get_selection_detailed(params)
      model = Sketchup.active_model
      selection = model.selection

      log "Getting detailed selection, count: #{selection.length}"

      selected_entities = selection.map do |entity|
        info = {
          id: entity.entityID,
          type: entity.typename,
          name: (entity.name rescue nil)
        }

        # Add bounds if available
        if entity.respond_to?(:bounds)
          bounds = entity.bounds
          info[:bounds] = {
            min: [bounds.min.x, bounds.min.y, bounds.min.z],
            max: [bounds.max.x, bounds.max.y, bounds.max.z],
            center: [bounds.center.x, bounds.center.y, bounds.center.z]
          }
        end

        # Add material if available
        if entity.respond_to?(:material) && entity.material
          info[:material] = entity.material.name
        end

        # Add layer if available
        if entity.respond_to?(:layer) && entity.layer
          info[:layer] = entity.layer.name
        end

        info
      end

      { success: true, entities: selected_entities, count: selection.length }
    end

    def select_by_id(params)
      entity_id = params["entity_id"]
      add_to_selection = params["add_to_selection"] || false

      model = Sketchup.active_model
      selection = model.selection

      log "Selecting entity #{entity_id}, add=#{add_to_selection}"

      entity = model.find_entity_by_id(entity_id)

      if entity
        if add_to_selection
          selection.add(entity)
        else
          selection.clear
          selection.add(entity)
        end
        { success: true, result: "Selected #{entity.typename}##{entity_id}" }
      else
        { success: false, result: "Entity #{entity_id} not found" }
      end
    end

    def clear_selection(params)
      model = Sketchup.active_model
      selection = model.selection

      log "Clearing selection"
      selection.clear

      { success: true, result: "Selection cleared" }
    end

    def select_by_bounding_box(params)
      min_point = params["min_point"]
      max_point = params["max_point"]
      add_to_selection = params["add_to_selection"] || false

      model = Sketchup.active_model
      selection = model.selection

      log "Selecting by bounding box: #{min_point} to #{max_point}"

      # Create bounding box
      bb = Geom::BoundingBox.new
      bb.add(Geom::Point3d.new(min_point[0], min_point[1], min_point[2]))
      bb.add(Geom::Point3d.new(max_point[0], max_point[1], max_point[2]))

      # Find entities within bounds
      selected = []
      model.entities.each do |entity|
        if entity.respond_to?(:bounds)
          entity_bb = entity.bounds
          # Check if entity bounds intersect with selection box
          if entity_bb.min.x <= bb.max.x && entity_bb.max.x >= bb.min.x &&
             entity_bb.min.y <= bb.max.y && entity_bb.max.y >= bb.min.y &&
             entity_bb.min.z <= bb.max.z && entity_bb.max.z >= bb.min.z
            selected << entity
          end
        end
      end

      # Update selection
      selection.clear unless add_to_selection
      selected.each { |e| selection.add(e) }

      { success: true, result: "Selected #{selected.length} entities" }
    end

    # ============================================================================
    # Entity Inspection Tools
    # ============================================================================

    def get_entity_by_id(params)
      entity_id = params["entity_id"]

      model = Sketchup.active_model
      log "Getting entity by ID: #{entity_id}"

      entity = model.find_entity_by_id(entity_id)

      if entity
        info = {
          id: entity.entityID,
          type: entity.typename,
          name: (entity.name rescue nil)
        }

        # Add bounds if available
        if entity.respond_to?(:bounds)
          bounds = entity.bounds
          info[:bounds] = {
            min: [bounds.min.x, bounds.min.y, bounds.min.z],
            max: [bounds.max.x, bounds.max.y, bounds.max.z]
          }
        end

        # Add transformation if available
        if entity.respond_to?(:transformation)
          t = entity.transformation
          info[:transformation] = {
            origin: [t.origin.x, t.origin.y, t.origin.z]
          }
        end

        { success: true, entity: info }
      else
        { success: false, result: "Entity #{entity_id} not found" }
      end
    end

    def list_entities(params)
      entity_type = params["entity_type"]
      limit = params["limit"] || 100

      model = Sketchup.active_model
      log "Listing entities, type=#{entity_type}, limit=#{limit}"

      entities = []
      count = 0

      model.entities.each do |entity|
        break if count >= limit

        if entity_type.nil? || entity.typename == entity_type
          entities << {
            id: entity.entityID,
            type: entity.typename,
            name: (entity.name rescue nil)
          }
          count += 1
        end
      end

      { success: true, entities: entities, total_count: model.entities.count }
    end

    def get_entity_properties(params)
      entity_id = params["entity_id"]

      model = Sketchup.active_model
      log "Getting entity properties for ID: #{entity_id}"

      entity = model.find_entity_by_id(entity_id)

      if entity
        properties = {
          id: entity.entityID,
          type: entity.typename,
          name: (entity.name rescue nil),
          valid: entity.valid?,
          deleted: entity.deleted?
        }

        # Add attribute dictionaries if any
        if entity.respond_to?(:attribute_dictionaries) && entity.attribute_dictionaries
          properties[:attributes] = {}
          entity.attribute_dictionaries.each do |dict|
            properties[:attributes][dict.name] = {}
            dict.each do |key, value|
              properties[:attributes][dict.name][key] = value
            end
          end
        end

        # Add entity-specific properties
        case entity
        when Sketchup::Face
          properties[:area] = entity.area
          properties[:material] = entity.material&.name
          properties[:back_material] = entity.back_material&.name
        when Sketchup::Edge
          properties[:length] = entity.length
          properties[:start] = [entity.start.position.x, entity.start.position.y, entity.start.position.z]
          properties[:end] = [entity.end.position.x, entity.end.position.y, entity.end.position.z]
        when Sketchup::Group, Sketchup::ComponentInstance
          properties[:definition] = entity.definition.name if entity.definition
        end

        { success: true, properties: properties }
      else
        { success: false, result: "Entity #{entity_id} not found" }
      end
    end

    # ============================================================================
    # Camera Tools
    # ============================================================================

    def get_camera(params)
      model = Sketchup.active_model
      view = model.active_view
      camera = view.camera

      log "Getting camera info"

      info = {
        eye: [camera.eye.x, camera.eye.y, camera.eye.z],
        target: [camera.target.x, camera.target.y, camera.target.z],
        up: [camera.up.x, camera.up.y, camera.up.z],
        direction: [camera.direction.x, camera.direction.y, camera.direction.z],
        fov: camera.fov,
        fov_is_height: camera.fov_is_height?,
        aspect_ratio: camera.aspect_ratio,
        perspective: camera.perspective?
      }

      { success: true, camera: info }
    end

    def set_camera(params)
      eye = params["eye"]
      target = params["target"]
      up = params["up"]

      model = Sketchup.active_model
      view = model.active_view
      camera = view.camera

      log "Setting camera: eye=#{eye}, target=#{target}"

      camera.set(
        Geom::Point3d.new(eye[0], eye[1], eye[2]),
        Geom::Point3d.new(target[0], target[1], target[2]),
        Geom::Vector3d.new(up[0], up[1], up[2])
      )

      view.invalidate

      { success: true, result: "Camera updated" }
    end

    def zoom_selection(params)
      model = Sketchup.active_model
      view = model.active_view
      selection = model.selection

      log "Zooming to selection"

      if selection.empty?
        return { success: false, error: "No selection to zoom to" }
      end

      # Calculate bounding box of selection
      bounds = Geom::BoundingBox.new
      selection.each do |entity|
        # Transform the entity bounds to world coordinates
        entity_bounds = entity.bounds
        bounds.add(entity_bounds.min)
        bounds.add(entity_bounds.max)
      end

      # Zoom to the bounds - use camera animation with the bounds center and diagonal
      if bounds.valid?
        diagonal = bounds.diagonal
        center = bounds.center
        # Set camera to look at center from a distance based on the diagonal
        eye = [center.x + diagonal, center.y + diagonal, center.z + diagonal/2]
        target = [center.x, center.y, center.z]
        up = [0, 0, 1]
        view.camera.set(eye, target, up)
        view.zoom_extents
      end

      { success: true, result: "Zoomed to selection" }
    end

    def zoom_extents(params)
      model = Sketchup.active_model
      view = model.active_view

      log "Zooming to extents"

      # Use SketchUp's zoom extents
      view.zoom_extents

      { success: true, result: "Zoomed to extents" }
    end

    # ============================================================================
    # Model Info Tools
    # ============================================================================

    def get_model_info(params)
      model = Sketchup.active_model

      log "Getting model info"

      # Get model bounds
      bb = model.bounds
      bounds = {
        min: [bb.min.x, bb.min.y, bb.min.z],
        max: [bb.max.x, bb.max.y, bb.max.z]
      }

      # Count entities by type
      entity_counts = Hash.new(0)
      model.entities.each do |entity|
        entity_counts[entity.typename] += 1
      end

      info = {
        path: model.path,
        title: model.title,
        bounds: bounds,
        entity_counts: entity_counts,
        total_entities: model.entities.count,
        selection_count: model.selection.length,
        active_layer: model.active_layer&.name,
        number_of_layers: model.layers.size,
        number_of_materials: model.materials.size,
        number_of_definitions: model.definitions.size
      }

      { success: true, model: info }
    end

    def list_layers(params)
      model = Sketchup.active_model

      log "Listing layers"

      layers = model.layers.map do |layer|
        {
          name: layer.name,
          visible: layer.visible?
        }
      end

      { success: true, layers: layers, active_layer: model.active_layer&.name }
    end

    def list_materials(params)
      model = Sketchup.active_model

      log "Listing materials"

      materials = model.materials.map do |material|
        info = {
          name: material.name,
          color: (material.color.to_s if material.color)
        }
        # Add texture info if available
        if material.texture
          info[:texture] = {
            filename: material.texture.filename,
            width: material.texture.width,
            height: material.texture.height
          }
        end
        info
      end

      { success: true, materials: materials }
    end

    def list_definitions(params)
      model = Sketchup.active_model

      log "Listing component definitions"

      definitions = model.definitions.map do |defn|
        {
          name: defn.name,
          guid: defn.guid,
          count: defn.count_instances,
          group: defn.group?,
          image: defn.image?,
          bounds: {
            min: [defn.bounds.min.x, defn.bounds.min.y, defn.bounds.min.z],
            max: [defn.bounds.max.x, defn.bounds.max.y, defn.bounds.max.z]
          }
        }
      end

      { success: true, definitions: definitions }
    end

    # ============================================================================
    # Extension Development Tools
    # ============================================================================

    def reload_extension(params)
      extension_name = params["extension_name"]

      log "Reloading extension: #{extension_name}"

      # Find the extension
      extension = Sketchup.extensions.find { |ext| ext.name == extension_name }

      if extension
        # Note: SketchUp doesn't provide a standard way to unload extensions
        # Extensions can only be disabled via the Preferences dialog
        # We can only report the extension status
        {
          success: true,
          result: "Extension #{extension_name} found (loaded: #{extension.loaded?}, enabled: #{extension.enabled?})",
          note: "SketchUp doesn't support programmatic extension reloading. Use Extensions > Extension Manager to manage extensions."
        }
      else
        { success: false, error: "Extension '#{extension_name}' not found" }
      end
    end

    def reload_file(params)
      file_path = params["file_path"]

      log "Reloading file: #{file_path}"

      begin
        if File.exist?(file_path)
          load file_path
          { success: true, result: "File #{file_path} reloaded" }
        else
          { success: false, result: "File not found: #{file_path}" }
        end
      rescue => e
        { success: false, result: "Error reloading file: #{e.message}" }
      end
    end

    def run_command(params)
      command_id = params["command_id"]

      log "Running command: #{command_id}"

      begin
        Sketchup.send_action(command_id)
        { success: true, result: "Command #{command_id} executed" }
      rescue => e
        { success: false, result: "Error running command: #{e.message}" }
      end
    end

    def list_commands(params)
      log "Listing available commands"

      # Common SketchUp commands
      commands = [
        { id: "selectSelectionTool:", name: "Select Tool", category: "Tools" },
        { id: "selectLineTool:", name: "Line Tool", category: "Draw" },
        { id: "selectRectangleTool:", name: "Rectangle Tool", category: "Draw" },
        { id: "selectCircleTool:", name: "Circle Tool", category: "Draw" },
        { id: "selectArcTool:", name: "Arc Tool", category: "Draw" },
        { id: "selectPolygonTool:", name: "Polygon Tool", category: "Draw" },
        { id: "selectFreehandTool:", name: "Freehand Tool", category: "Draw" },
        { id: "selectPushPullTool:", name: "Push/Pull Tool", category: "Tools" },
        { id: "selectMoveTool:", name: "Move Tool", category: "Tools" },
        { id: "selectRotateTool:", name: "Rotate Tool", category: "Tools" },
        { id: "selectScaleTool:", name: "Scale Tool", category: "Tools" },
        { id: "selectOffsetTool:", name: "Offset Tool", category: "Tools" },
        { id: "showRubyPanel:", name: "Show Ruby Console", category: "Window" },
        { id: "viewZoomExtents:", name: "Zoom Extents", category: "Camera" },
        { id: "viewZoomToSelection:", name: "Zoom Selection", category: "Camera" },
        { id: "viewZoomIn:", name: "Zoom In", category: "Camera" },
        { id: "viewZoomOut:", name: "Zoom Out", category: "Camera" },
        { id: "viewIso:", name: "Isometric View", category: "Camera" },
        { id: "viewFront:", name: "Front View", category: "Camera" },
        { id: "viewBack:", name: "Back View", category: "Camera" },
        { id: "viewTop:", name: "Top View", category: "Camera" },
        { id: "viewBottom:", name: "Bottom View", category: "Camera" },
        { id: "viewLeft:", name: "Left View", category: "Camera" },
        { id: "viewRight:", name: "Right View", category: "Camera" },
        { id: "editUndo:", name: "Undo", category: "Edit" },
        { id: "editRedo:", name: "Redo", category: "Edit" },
        { id: "editCut:", name: "Cut", category: "Edit" },
        { id: "editCopy:", name: "Copy", category: "Edit" },
        { id: "editPaste:", name: "Paste", category: "Edit" },
        { id: "editSelectAll:", name: "Select All", category: "Edit" },
        { id: "editSelectNone:", name: "Select None", category: "Edit" },
        { id: "editDelete:", name: "Delete", category: "Edit" },
        { id: "editHide:", name: "Hide", category: "Edit" },
        { id: "editUnhideAll:", name: "Unhide All", category: "Edit" },
        { id: "editLock:", name: "Lock", category: "Edit" },
        { id: "editUnlockAll:", name: "Unlock All", category: "Edit" },
        { id: "editGroup:", name: "Group", category: "Edit" },
        { id: "editExplode:", name: "Explode", category: "Edit" },
        { id: "editIntersectWithModel:", name: "Intersect with Model", category: "Edit" },
        { id: "pageAdd:", name: "Add Scene", category: "Scenes" },
        { id: "pageDelete:", name: "Delete Scene", category: "Scenes" },
        { id: "pageNext:", name: "Next Scene", category: "Scenes" },
        { id: "pagePrevious:", name: "Previous Scene", category: "Scenes" },
        { id: "pageUpdate:", name: "Update Scene", category: "Scenes" },
        { id: "renderWireframe:", name: "Wireframe Rendering", category: "View" },
        { id: "renderHiddenLine:", name: "Hidden Line Rendering", category: "View" },
        { id: "renderShadow:", name: "Shadow Rendering", category: "View" },
        { id: "renderTexture:", name: "Shaded Rendering", category: "View" },
        { id: "renderMonochrome:", name: "Monochrome Rendering", category: "View" },
        { id: "toggleShadows:", name: "Toggle Shadows", category: "View" },
        { id: "toggleXray:", name: "Toggle X-Ray", category: "View" },
        { id: "toggleTransparency:", name: "Toggle Transparency", category: "View" },
        { id: "toggleAxes:", name: "Toggle Axes", category: "View" },
        { id: "toggleGuides:", name: "Toggle Guides", category: "View" },
        { id: "toggleSectionPlanes:", name: "Toggle Section Planes", category: "View" },
        { id: "toggleHidden:", name: "Toggle Hidden Objects", category: "View" },
        { id: "fixCamera:", name: "Fix Camera for Photo Match", category: "Camera" },
        { id: "editToggleHideRestOfModel:", name: "Toggle Hide Rest of Model", category: "Edit" },
        { id: "editToggleHideSimilarComponents:", name: "Toggle Hide Similar Components", category: "Edit" },
        { id: "editToggleComponentAxes:", name: "Toggle Component Axes", category: "Edit" },
        { id: "selectEraseTool:", name: "Eraser Tool", category: "Tools" },
        { id: "selectPaintBucketTool:", name: "Paint Bucket Tool", category: "Tools" },
        { id: "selectPositionCameraTool:", name: "Position Camera Tool", category: "Camera" },
        { id: "selectWalkTool:", name: "Walk Tool", category: "Camera" },
        { id: "selectLookAroundTool:", name: "Look Around Tool", category: "Camera" },
        { id: "selectTextTool:", name: "Text Tool", category: "Tools" },
        { id: "selectDimensionTool:", name: "Dimension Tool", category: "Tools" },
        { id: "selectSectionPlaneTool:", name: "Section Plane Tool", category: "Tools" },
        { id: "selectProtractorTool:", name: "Protractor Tool", category: "Tools" },
        { id: "selectTapeMeasureTool:", name: "Tape Measure Tool", category: "Tools" },
        { id: "selectAxesTool:", name: "Axes Tool", category: "Tools" },
        { id: "selectAddLocationTool:", name: "Add Location", category: "File" },
        { id: "selectGenerateBufferFacesTool:", name: "Generate Buffer Faces", category: "Tools" },
        { id: "selectGetTimeTool:", name: "Get Time (Sun Position)", category: "View" },
        { id: "selectSetTimeTool:", name: "Set Time (Sun Position)", category: "View" },
        { id: "selectSetNorthTool:", name: "Set North", category: "View" },
        { id: "editMakeComponent:", name: "Make Component", category: "Edit" },
        { id: "editMakeGroup:", name: "Make Group", category: "Edit" },
        { id: "editCloseComponent:", name: "Close Component/Group", category: "Edit" },
        { id: "editComponentEdit:", name: "Edit Component", category: "Edit" },
        { id: "editFlipAlongComponentRed:", name: "Flip Along Component Red", category: "Edit" },
        { id: "editFlipAlongComponentGreen:", name: "Flip Along Component Green", category: "Edit" },
        { id: "editFlipAlongComponentBlue:", name: "Flip Along Component Blue", category: "Edit" },
        { id: "editFlipAlongRed:", name: "Flip Along Red", category: "Edit" },
        { id: "editFlipAlongGreen:", name: "Flip Along Green", category: "Edit" },
        { id: "editFlipAlongBlue:", name: "Flip Along Blue", category: "Edit" },
        { id: "editComponentAxes:", name: "Change Component Axes", category: "Edit" },
        { id: "editComponentScaleDefinition:", name: "Scale Component Definition", category: "Edit" },
        { id: "editComponentResetScale:", name: "Reset Component Scale", category: "Edit" },
        { id: "editComponentReload:", name: "Reload Component", category: "Edit" },
        { id: "editComponentSaveAs:", name: "Save Component As", category: "Edit" },
        { id: "editComponentResetContext:", name: "Reset Component Context", category: "Edit" },
        { id: "editComponentExplode:", name: "Explode Component", category: "Edit" },
        { id: "editTexturePosition:", name: "Texture Position", category: "Edit" },
        { id: "editTextureResetPosition:", name: "Reset Texture Position", category: "Edit" },
        { id: "editTextureProjection:", name: "Texture Projection", category: "Edit" },
        { id: "editTextureColorize:", name: "Colorize Texture", category: "Edit" },
        { id: "editTextureProjected:", name: "Toggle Projected Texture", category: "Edit" },
        { id: "editInvertSelection:", name: "Invert Selection", category: "Edit" }
      ]

      { success: true, commands: commands, count: commands.length }
    end

    # ============================================================================
    # Console and Logging Tools
    # ============================================================================

    def get_console_logs(params)
      limit = params["limit"] || 100

      log "Getting console logs (last #{limit} entries)"

      # In SketchUp, we can't easily access the console history
      # This returns a placeholder - in a full implementation, you'd need
      # to hook into console output
      { success: true, logs: [], message: "Console logs not available in this implementation" }
    end

    def clear_console(params)
      log "Clearing console"

      begin
        # Try to clear the console using the console object
        if defined?(SKETCHUP_CONSOLE)
          SKETCHUP_CONSOLE.clear
        end
        { success: true, result: "Console cleared" }
      rescue => e
        { success: false, result: "Could not clear console: #{e.message}" }
      end
    end

    def show_ruby_console(params)
      log "Showing Ruby console"

      begin
        SKETCHUP_CONSOLE.show
        { success: true, result: "Ruby console shown" }
      rescue => e
        # Fallback: try send_action
        begin
          Sketchup.send_action("showRubyPanel:")
          { success: true, result: "Ruby console shown (via send_action)" }
        rescue => e2
          { success: false, result: "Could not show console: #{e2.message}" }
        end
      end
    end
  end

  unless file_loaded?(__FILE__)
    @server = Server.new
    
    menu = UI.menu("Plugins").add_submenu("MCP Server")
    menu.add_item("Start Server") { @server.start }
    menu.add_item("Stop Server") { @server.stop }
    
    file_loaded(__FILE__)
  end
end 