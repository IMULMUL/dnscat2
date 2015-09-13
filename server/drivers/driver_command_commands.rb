##
# driver_command.rb
# Created September 13, 2015
# By Ron Bowes
#
# See: LICENSE.md
##

module DriverCommandCommands
  def _display_window(window, all, indent = 0)
    if(!all && window.closed?())
      return
    end

    @window.puts(('  ' * indent) + window.to_s())
    window.children() do |c|
      _display_window(c, all, indent + 1)
    end
  end

  def _display_windows(all)
    _display_window(@window, all)
  end

  def _register_commands()
    @commander.register_alias('sessions', 'windows')
    @commander.register_alias('session',  'window')
    @commander.register_alias('q',        'quit')
    @commander.register_alias('exit',     'quit')

    @commander.register_command('echo',
      Trollop::Parser.new do
        banner("Print stuff to the terminal, including $variables")
      end,

      Proc.new do |opts, optarg|
        @window.puts(optarg)
      end
    )

    @commander.register_command("ping",
      Trollop::Parser.new do
        banner("Sends a 'ping' to the remote host to make sure it's still alive)")
        opt :length, "length", :type => :integer, :required => false, :default => 256
      end,
      Proc.new do |opts|
        ping = CommandPacket.new({
          :is_request => true,
          :request_id => request_id(),
          :command_id => CommandPacket::COMMAND_PING,
          :data       => (0...opts[:length]).map { ('A'.ord + rand(26)).chr }.join()
        })

        _send_request(ping) do |request, response|
          if(request.get(:data) != response.get(:data))
            @window.puts("The server didn't return the same ping data we sent!")
            @window.puts("Expected: #{request.get(:data)}")
            @window.puts("Received: #{response.get(:data)}")
          else
            @window.puts("Pong!")
          end
        end

        @window.puts("Ping!")
      end,
    )

    @commander.register_command("clear",
      Trollop::Parser.new do
        banner("Clears the display")
      end,
      Proc.new do |opts|
        0.upto(100) do @window.puts() end
      end,
    )


    @commander.register_command("shell",
      Trollop::Parser.new do
        banner("Spawn a shell on the remote host")
        opt :name, "Name", :type => :string, :required => false, :default => nil
      end,

      Proc.new do |opts|
        shell = CommandPacket.new({
          :is_request => true,
          :request_id => request_id(),
          :command_id => CommandPacket::COMMAND_SHELL,
          :name       => opts[:name] || "shell"
        })

        _send_request(shell) do |request, response|
          @window.puts("Shell session created: #{response.get(:session_id)}")
        end

        @window.puts("Sent request to execute a shell")
      end,
    )

    @commander.register_command("exec",
      Trollop::Parser.new do
        banner("Execute a program on the remote host")
        opt :command, "Command", :type => :string, :required => false, :default => nil
        opt :name,    "Name",    :type => :string, :required => false, :default => nil
      end,

      Proc.new do |opts, optarg|
        command = opts[:command] || optarg
        name    = opts[:name]    || command

        if(name == "")
          @window.puts("No command given!")
          @window.puts()
          raise(Trollop::HelpNeeded)
        end

        puts("command = #{command} #{command.class}")
        exec = CommandPacket.new({
          :is_request => true,
          :request_id => request_id(),
          :command_id => CommandPacket::COMMAND_EXEC,
          :command => command,
          :name => name,
        })

        _send_request(exec) do |request, response|
          @window.puts("Executed \"#{request.get(:command)}\": #{response.get(:session_id)}")
        end

        @window.puts("Sent request to execute \"#{command}\"")
      end,
    )

    @commander.register_command("suspend",
      Trollop::Parser.new do
        banner("Go back to the parent session")
      end,

      Proc.new do |opts, optarg|
        @window.deactivate()
      end,
    )

    @commander.register_command("download",
      Trollop::Parser.new do
        banner("Download a file off the remote host. Usage: download <from> [to]")
      end,

      Proc.new do |opts, optarg|
        # Get the two files
        remote_file, local_file = Shellwords.shellwords(optarg)

        # Sanity check
        if(remote_file.nil? || remote_file == "")
          @window.puts("Usage: download <from> [to]")
        else
          # Make sure we have a local file
          if(local_file.nil? || local_file == "")
            # I only want the filename to prevent accidental traversal
            local_file = File.basename(remote_file)
          end

          download = CommandPacket.new({
            :is_request => true,
            :request_id => request_id(),
            :command_id => CommandPacket::COMMAND_DOWNLOAD,
            :filename => remote_file,
          })

          _send_request(download) do |request, response|
            File.open(local_file, "wb") do |f|
              f.write(response.get(:data))
              @window.puts("Wrote #{response.get(:data).length} bytes from #{request.get(:filename)} to #{local_file}!")
            end
          end

          @window.puts("Attempting to download #{remote_file} to #{local_file}")
        end
      end
    )

    @commander.register_command("upload",
      Trollop::Parser.new do
        banner("Upload a file off the remote host. Usage: upload <from> <to>")
      end,

      Proc.new do |opts, optarg|
        # Get the two files
        local_file, remote_file = Shellwords.shellwords(optarg)

        # Sanity check
        if(local_file.nil? || local_file == "" || remote_file.nil? || remote_file == "")
          @window.puts("Usage: upload <from> <to>")
        else
          data = IO.read(local_file)

          upload = CommandPacket.new({
            :is_request => true,
            :request_id => request_id(),
            :command_id => CommandPacket::COMMAND_UPLOAD,
            :filename => remote_file,
            :data => data,
          })

          _send_request(upload) do |request, response|
            @window.puts("#{data.length} bytes uploaded from #{local_file} to #{remote_file}")
          end

          @window.puts("Attempting to upload #{local_file} to #{remote_file}")
        end
      end
    )

    @commander.register_command("shutdown",
      Trollop::Parser.new do
        banner("Shut down the remote session")
      end,

      Proc.new do |opts, optarg|
        _send_request(CommandPacket.create_shutdown_request(request_id())) do |request, response|
          @window.puts("TODO: handle shutdown() response")
        end
        @window.puts("Attempting to shut down remote session(s)...")
      end
    )

    # This is almost the same as 'set' from 'controller', except it uses the
    # local settings and recurses into global if necessary
    @commander.register_command("set",
      Trollop::Parser.new do
        banner("set <name>=<value>")
      end,

      Proc.new do |opts, optarg|
        if(optarg.length == 0)
          @window.puts("Usage: set <name>=<value>")
          @window.puts()
          @window.puts("Global options:")
          Settings::GLOBAL.each_pair() do |k, v|
            @window.puts(" %s=%s" % [k, v.to_s()])
          end

          @window.puts()
          @window.puts("Session options:")
          @settings.each_pair() do |k, v|
            @window.puts(" %s=%s" % [k, v.to_s()])
          end

          next
        end

        # Split at the '=' sign
        namevalue = optarg.split("=", 2)

        if(namevalue.length != 2)
          namevalue = optarg.split(" ", 2)
        end

        if(namevalue.length != 2)
          @window.puts("Bad argument! Expected: 'set <name>=<value>' or 'set name value'!")
          @window.puts()
          raise(Trollop::HelpNeeded)
        end

        begin
          @settings.set(namevalue[0], namevalue[1], true)
        rescue Settings::ValidationError => e
          @window.puts("Failed to set the new value: #{e}")
        end
      end
    )

    @commander.register_command('windows',
      Trollop::Parser.new do
        banner("Lists the current active windows")
        opt :all, "Show closed windows", :type => :boolean, :required => false
      end,

      Proc.new do |opts, optarg|
        _display_windows(opts[:all])
      end,
    )

    @commander.register_command("window",
      Trollop::Parser.new do
        banner("Interact with a window")
        opt :i, "Interact with the chosen window", :type => :string, :required => false
      end,

      Proc.new do |opts, optarg|
        if(opts[:i].nil?)
          _display_windows(opts[:all])
          next
        end

        if(!SWindow.activate(opts[:i]))
          @window.puts("Window #{opts[:i]} not found!")
          @window.puts()
          _display_windows(false)
          next
        end
      end
    )

    @commander.register_command("quit",
      Trollop::Parser.new do
        banner("Close all sessions and exit dnscat2")
      end,

      Proc.new do |opts, optarg|
        exit(0)
      end
    )
  end
end