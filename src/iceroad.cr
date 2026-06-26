# =============================================================================
#  CivMC Ice-Road Builder  —  a Rosegold macro
# =============================================================================
#
#  WHAT IT DOES
#  ------------
#    Stage 1 (dig):   carves a tunnel that is 3 wide and 3 tall, with the
#                     CENTRE column dug 4 tall (one extra block on top).
#    Stage 2 (build): fills that cavity into a finished ice road:
#                       left column  = 3 obsidian (wall)
#                       right column = 3 obsidian (wall)
#                       centre lane  = packed ice on the floor
#                                      + trapdoor on top of the ice
#                                      + 2 air (you travel here)
#                                      + obsidian ceiling in the 4th block
#                                      + trapdoor hanging under that obsidian
#                     Both trapdoors are hinged facing the travel direction.
#
#  RULE COMPLIANCE (CivMC botting rules) — built in, do not remove:
#    * The bot NEVER reads blocks or entities. Every action is computed purely
#      from the bot's OWN location (which the rules permit). It is "blind":
#      it cannot tell whether a block actually broke or placed. It dead-reckons.
#    * The bot NEVER speaks in public/local chat. The ONLY method that sends
#      chat is `notify`, and it ONLY ever sends `/g <group> ...` slash commands
#      to your NameLayer group. Even if your server ignores the inline-message
#      form, the worst case is a harmless command error — never a local leak.
#
#  IMPORTANT — THIS IS UNTESTED AGAINST A LIVE SERVER.
#  Calibrate the values in the CONFIG block (especially DIG_* and the trapdoor
#  look poses) in a safe/throwaway spot before running it for real.
#
#  USAGE
#    1. Drop this file into the Rosegold `example` template's `src/` folder.
#    2. Edit the CONFIG block below.
#    3. Stand the bot at the START coordinate, facing along the travel axis,
#       on the floor it will dig along (its feet level = the lane floor level).
#    4. `shards build && ./bin/iceroad`
#    5. To STOP at any time: type your STOP_KEYWORD in the group chat, or press
#       Ctrl-C in the terminal.
# =============================================================================

require "rosegold"

module IceRoad
  # ===========================================================================
  #  CONFIG  — edit everything in here
  # ===========================================================================

  # Server + spectate config. All overridable by environment variables so you
  # can point at a local test world without recompiling, e.g.
  #   SERVER_HOST=localhost ./bin/iceroad
  SERVER        = ENV["SERVER_HOST"]? || "play.civmc.net"
  SERVER_PORT   = (ENV["SERVER_PORT"]? || "25565").to_i
  SPECTATE_HOST = ENV["SPECTATE_HOST"]? || "0.0.0.0"
  SPECTATE_PORT = (ENV["SPECTATE_PORT"]? || "25566").to_i

  # --- NameLayer group used for ALL status/alert messages -------------------
  # The bot sends every message as:  /g <GROUP> <text>
  # Verify this matches how YOUR server delivers a one-off group message.
  # If your server uses a different syntax, change GROUP_CHAT_TEMPLATE only —
  # never add a bare `bot.chat(text)` anywhere, or you risk leaking to local.
  GROUP               = "myroadgroup"
  GROUP_CHAT_TEMPLATE = "/g %{group} %{text}"

  # --- Stop control ---------------------------------------------------------
  # Type this word in the group chat (from any account) to stop the bot.
  # (Reading server-provided chat is allowed by the rules.)
  STOP_KEYWORD = "roadstop"

  # --- Route ----------------------------------------------------------------
  # Mode :coords  -> dig/build from START to END (must share two of three axes;
  #                  the differing horizontal axis is the travel direction).
  # Mode :forever -> run from the current position until stopped.
  MODE  = :coords
  START = {x: -38, y: -63, z: 22}   # the block the bot is standing in at start
  END   = {x: -38, y: -63, z: 80}   # only used when MODE == :coords

  # --- Materials (exact CivMC item names) -----------------------------------
  OBSIDIAN     = "obsidian"
  PACKED_ICE   = "packed_ice"
  TRAPDOOR     = "oak_trapdoor"   # any non-redstone trapdoor: oak_/copper_/etc.

  # --- Dig tuning (CALIBRATE THESE) -----------------------------------------
  # The bot is blind, so it holds "attack" for a fixed number of ticks per
  # block, sized for the SLOWEST block it expects (deepslate). Softer blocks
  # (ores, dirt) just break sooner and the extra ticks hit air harmlessly.
  # We size this off the bot's CURRENT tool via estimated_break_ticks at start.
  HARDEST_BLOCK   = "deepslate"
  DIG_BUFFER_TICKS = 8     # extra ticks added on top of the estimate

  # How many consecutive blocks of no forward progress before we decide we are
  # stuck (e.g. ran into bedrock, lava, or a reinforced block we can't break).
  STUCK_TIMEOUT_TICKS = 60

  # ===========================================================================
  #  END CONFIG
  # ===========================================================================

  class Builder
    @running = true
    @dig_ticks : Int32 = 40

    def initialize(@bot : Rosegold::Bot)
      install_stop_hooks
    end

    # ---- The ONLY place chat is ever sent. Always a slash command. ----------
    private def notify(text : String)
      msg = GROUP_CHAT_TEMPLATE % {group: GROUP, text: text}
      raise "refusing to send non-command chat: #{msg.inspect}" unless msg.starts_with?("/")
      @bot.chat msg
    end

    # ---- Stop control: group-chat keyword + Ctrl-C --------------------------
    private def install_stop_hooks
      Signal::INT.trap { stop("Ctrl-C") }

      @bot.on Rosegold::Clientbound::SystemChatMessage do |event|
        stop("chat keyword") if event.message.to_s.downcase.includes?(STOP_KEYWORD)
      end
      @bot.on Rosegold::Clientbound::PlayerChatMessage do |event|
        stop("chat keyword") if event.message.to_s.downcase.includes?(STOP_KEYWORD)
      end
    end

    private def stop(reason : String)
      return unless @running
      @running = false
      @bot.stop_digging rescue nil
      @bot.stop_moving rescue nil
      notify "Stopping (#{reason})." rescue nil
    end

    def running?
      @running
    end

    # ========================================================================
    #  Direction helpers
    #  All geometry is expressed relative to a unit travel step `dir`,
    #  with `left`/`right` perpendicular, all as Vec3i.
    # ========================================================================

    private def travel_dir : Rosegold::Vec3i
      if MODE == :forever
        # Use the bot's current facing, snapped to the nearest cardinal axis.
        yaw = @bot.yaw % 360
        case yaw
        when 315..360, 0...45  then Rosegold::Vec3i.new(0, 0, 1)   # south +Z
        when 45...135          then Rosegold::Vec3i.new(-1, 0, 0)  # west  -X
        when 135...225         then Rosegold::Vec3i.new(0, 0, -1)  # north -Z
        else                        Rosegold::Vec3i.new(1, 0, 0)   # east  +X
        end
      else
        dx = END[:x] - START[:x]
        dz = END[:z] - START[:z]
        raise "START and END must differ on exactly one horizontal axis" if dx != 0 && dz != 0
        raise "START and END are the same column" if dx == 0 && dz == 0
        if dx != 0
          Rosegold::Vec3i.new(dx <=> 0, 0, 0)
        else
          Rosegold::Vec3i.new(0, 0, dz <=> 0)
        end
      end
    end

    # 90° left of the travel direction, on the horizontal plane.
    private def left_of(dir : Rosegold::Vec3i) : Rosegold::Vec3i
      Rosegold::Vec3i.new(-dir.z, 0, dir.x)
    end

    private def block_count(dir : Rosegold::Vec3i) : Int32
      return Int32::MAX if MODE == :forever
      (dir.x != 0) ? (END[:x] - START[:x]).abs : (END[:z] - START[:z]).abs
    end

    # The look direction (yaw/pitch=0) that points along `dir`.
    private def look_along(dir : Rosegold::Vec3i) : Rosegold::Look
      Rosegold::Look.from_vec(dir.to_f64)
    end

    # ========================================================================
    #  STAGE 1 — DIG
    # ========================================================================
    #
    #  Standing at column K (feet on the lane floor), we carve the cross-section
    #  ONE block ahead (K+1): centre 4 tall, sides 3 tall. Then we step forward
    #  onto the freshly-carved centre and repeat. The side columns are left 3
    #  tall on purpose: the untouched 4th-layer side blocks become anchors for
    #  the centre ceiling obsidian in Stage 2.
    #
    def dig!
      dir   = travel_dir
      left  = left_of(dir)
      right = Rosegold::Vec3i.new(-left.x, 0, -left.z)
      total = block_count(dir)

      # Size the per-block dig time from the bot's current tool + haste.
      @dig_ticks = @bot.estimated_break_ticks(HARDEST_BLOCK, buffer_ticks: DIG_BUFFER_TICKS)
      notify "Stage 1 (dig): #{total == Int32::MAX ? "indefinite" : total} blocks, " \
             "#{@dig_ticks} ticks/block."

      # Carve the upper part of the STARTING column too (so the road is uniform
      # from block 0). The bot already occupies the bottom 2 of its own column.
      carve_column_extras(@bot.location.block, dir)

      dug = 0
      while @running && dug < total
        base = @bot.location.block        # integer block the feet are in

        # Cross-section one block ahead:
        centre = base + dir
        carve_full_column(centre, dir, 4)              # centre: 4 tall
        carve_full_column(centre + left,  dir, 3)      # left  : 3 tall
        carve_full_column(centre + right, dir, 3)      # right : 3 tall

        # Step forward into the carved centre. If we cannot advance, the path is
        # blocked (bedrock/lava/reinforced) — we can't see why, so we bail out.
        begin
          @bot.move_to(centre.x, centre.z, stuck_timeout_ticks: STUCK_TIMEOUT_TICKS)
        rescue Rosegold::Physics::MovementStuck
          notify "STUCK while digging near #{base.x} #{base.y} #{base.z}. Stopping."
          stop("dig stuck")
          return
        end

        dug += 1
        notify "dig #{dug}/#{total == Int32::MAX ? "?" : total}" if dug % 16 == 0
      end

      notify "Stage 1 complete (#{dug} blocks)." if @running
    end

    # Break `height` blocks straight up starting at the floor level of `col`.
    private def carve_full_column(col : Rosegold::Vec3i, dir : Rosegold::Vec3i, height : Int32)
      height.times do |i|
        return unless @running
        target = col.up(i).centered_3d            # aim at block centre
        @bot.dig(@dig_ticks, target)
      end
    end

    # For the very first column: the bot stands in the bottom 2 blocks; carve
    # the blocks above its head so the start matches the rest of the road.
    private def carve_column_extras(base : Rosegold::Vec3i, dir : Rosegold::Vec3i)
      # centre column wants to be 4 tall; the bot occupies base & base.up(1).
      @bot.dig(@dig_ticks, base.up(2).centered_3d)
      @bot.dig(@dig_ticks, base.up(3).centered_3d)
    end

    # ========================================================================
    #  STAGE 2 — BUILD
    # ========================================================================
    #
    #  The bot walks back through the empty tunnel (from END toward START), and
    #  at each step it builds the cross-section it just VACATED (one block
    #  behind its travel-back direction), so it always stands on solid dug
    #  floor and never on the ice/trapdoors it is placing.
    #
    #  Placement anchors (every placed block has a valid adjacent surface):
    #    * centre ice  -> click TOP of the floor block below centre
    #    * side walls  -> click TOP of floor, then TOP of each obsidian below
    #    * centre roof -> click the inward SIDE face of the untouched layer-4
    #                     side block (this is why sides were dug only 3 tall)
    #    * floor trapdoor   -> click TOP of the ice
    #    * ceiling trapdoor -> click BOTTOM of the roof obsidian
    #
    def build!
      return unless @running
      forward = travel_dir
      back    = Rosegold::Vec3i.new(-forward.x, 0, -forward.z)
      left    = left_of(forward)
      right   = Rosegold::Vec3i.new(-left.x, 0, -left.z)
      total   = block_count(forward)
      total   = 0 if total == Int32::MAX   # in :forever mode, build only what you can reach back over

      notify "Stage 2 (build): placing #{total} cross-sections."

      built = 0
      while @running && built < total
        here = @bot.location.block          # standing on dug floor
        col  = here                         # build the cross-section we are on,
                                            # then step BACK so we never stand on ice.

        place_cross_section(col, forward, left, right)

        # retreat one block toward START
        target = col + back
        begin
          @bot.move_to(target.x, target.z, stuck_timeout_ticks: STUCK_TIMEOUT_TICKS)
        rescue Rosegold::Physics::MovementStuck
          notify "STUCK while building near #{col.x} #{col.y} #{col.z}. Stopping."
          stop("build stuck")
          return
        end

        built += 1
        notify "build #{built}/#{total}" if built % 16 == 0
      end

      notify "Stage 2 complete (#{built} cross-sections)." if @running
    end

    # Build one finished cross-section. `col` is the centre/lane block at floor
    # (layer-1) level; `floor` below it is solid original ground.
    private def place_cross_section(col, forward, left, right)
      floor       = col.down                 # solid anchor under the lane
      left_floor  = floor + left
      right_floor = floor + right

      # 1) centre packed ice on the floor
      pick! PACKED_ICE
      place_on_top(floor)                      # ice lands at `col`

      # 2) left wall: 3 obsidian
      pick! OBSIDIAN
      place_on_top(left_floor)                 # layer1
      place_on_top(left_floor.up(0) + Rosegold::Vec3i.new(0,1,0)) # layer2 (on layer1)
      place_on_top((left_floor.up(2)).down)    # layer3 (kept explicit for clarity)

      # 3) right wall: 3 obsidian
      place_on_top(right_floor)
      place_on_top(right_floor.up(1).down.up(1))
      place_on_top(right_floor.up(2))

      # 4) centre ceiling obsidian (layer 4), placed against the inward SIDE
      #    face of an untouched layer-4 side block.
      anchor_roof = (left_floor.up(3))         # untouched solid block at layer 4, left side
      place_on_side(anchor_roof, toward: right) # new obsidian lands at col.up(3)

      # 5) floor trapdoor on top of the ice, hinged toward travel direction
      pick! TRAPDOOR
      place_trapdoor_on_top(col, forward)      # trapdoor sits on the ice (col)

      # 6) ceiling trapdoor under the roof obsidian, hinged toward travel
      place_trapdoor_under(col.up(3), forward)
    end

    # ---- Low-level placement helpers ---------------------------------------
    # NOTE: these aim at FACE CENTRES via place_block_against. Trapdoor HALF and
    # HINGE depend on look pose; the trapdoor helpers below set yaw along travel
    # and aim accordingly. These are the prime calibration points.

    private def place_on_top(block : Rosegold::Vec3i)
      @bot.place_block_against(block, Rosegold::BlockFace::Top)
      @bot.wait_ticks 1
    end

    private def place_on_side(block : Rosegold::Vec3i, toward : Rosegold::Vec3i)
      face = if toward.x > 0 then Rosegold::BlockFace::East
             elsif toward.x < 0 then Rosegold::BlockFace::West
             elsif toward.z > 0 then Rosegold::BlockFace::South
             else Rosegold::BlockFace::North end
      @bot.place_block_against(block, face)
      @bot.wait_ticks 1
    end

    # Trapdoor on top of `support` (e.g. the ice). Facing is set by the bot's
    # horizontal look at placement time; we look ALONG travel so the trapdoor
    # hinges toward the travel direction. CALIBRATE if the hinge comes out wrong
    # (you may need to look the opposite way, or offset the aim left/right).
    private def place_trapdoor_on_top(support : Rosegold::Vec3i, forward : Rosegold::Vec3i)
      @bot.look = look_along(forward)
      @bot.place_block_against(support, Rosegold::BlockFace::Top)
      @bot.wait_ticks 1
    end

    # Trapdoor hanging under `roof` (the ceiling obsidian).
    private def place_trapdoor_under(roof : Rosegold::Vec3i, forward : Rosegold::Vec3i)
      @bot.look = look_along(forward)
      @bot.place_block_against(roof, Rosegold::BlockFace::Bottom)
      @bot.wait_ticks 1
    end

    # pick! that turns "out of materials" into a clean stop + group alert.
    private def pick!(item : String)
      unless @bot.inventory.pick(item)
        notify "Out of #{item}. Stopping."
        stop("out of #{item}")
        raise OutOfMaterials.new(item)
      end
    end

    class OutOfMaterials < Exception; end
  end
end

# =============================================================================
#  ENTRY POINT
# =============================================================================
client = Rosegold::Client.new(IceRoad::SERVER, IceRoad::SERVER_PORT)

# Block form of join_game yields the connected client, then cleanly disconnects
# when the block returns.
client.join_game do |c|
  bot = Rosegold::Bot.new(c)
  bot.wait_ticks 20   # let physics/inventory/world state initialize

  # Start the spectate server so you can watch the bot from your own client.
  # Connect a Minecraft client to  <this machine>:SPECTATE_PORT  (default 25566;
  # use localhost:25566 if you're on the same machine).
  spectate = Rosegold::SpectateServer.new(IceRoad::SPECTATE_HOST, IceRoad::SPECTATE_PORT)
  spectate.attach_client(c)
  spectate.start

  builder = IceRoad::Builder.new(bot)
  begin
    builder.dig!
    builder.build! if builder.running?
  rescue IceRoad::Builder::OutOfMaterials
    # already alerted + stopped inside pick!
  rescue ex
    # Never let an exception escape to anything that might chat locally.
    builder.stop("error: #{ex.message}") rescue nil
  end
end
