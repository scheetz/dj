
module DockerJockey

  def self.docker_exec(image, args, options)
    docker_run(image, args, options)
  end

  def self.docker_exec_script(image, script, options)
    # TODO: change this to use docker api, like docker exec
    # write script and mount inside container
    File.write('__uberscript__', script)
    args = "chmod a+x __uberscript__ && ./__uberscript__"
    docker_run(image, args, options)
    File.delete('__uberscript__')
  end

  def self.docker_run(image, args, options=OpenStruct.new)
    # mounts = DockerJockey.docker_host[]
    if !image.include? ':'
      image = image + ":latest" # was getting "No such image" error without this
    end
    DockerJockey.logger.debug("docker_exec args: #{args.inspect}")
    cmd = args.is_a?(String) ? ['sh', '-c', "#{args}"] : args
    coptions = {
      'Image' => image,
      'Cmd' => cmd,
            # "AttachStdin": true,
            # "Tty": true,
      #  "OpenStdin": true,
      #  "StdinOnce": true,
      "AttachStdout": true,
      "AttachStderr": true,
      # 'Mounts' => mounts,
      # "Env": [
              #  "FOO=bar",
              #  "BAZ=quux"
      #  ],
      'WorkingDir' => '/app',
      'HostConfig' => {},
    }
    if DockerJockey.docker_host
      # Dind version
      coptions["HostConfig"]['VolumesFrom'] = [DockerJockey.docker_host['Name']]
      coptions["HostConfig"]['Binds'] = DockerJockey.docker_host['HostConfig']['Binds']
      # 'PortBindings': DockerJockey.docker_host['HostConfig']['PortBindings'],
    else
      coptions['Volumes'] = { '/app' => {} }
      coptions["HostConfig"]['Binds'] = ["#{Dir.pwd}:/app"]
    end

    if options.env_vars && options.env_vars.length > 0
      coptions['Env'] = options.env_vars
    end
    if options.ports && options.ports.length > 0
      # info: http://stackoverflow.com/a/20429133/105562
      coptions['ExposedPorts'] = {}
      coptions['HostConfig']['PortBindings'] = {}
      options.ports.each do |p|
        psplit = p.split(':')
        coptions['ExposedPorts']["#{psplit[1]}/tcp"] = {}
        coptions['HostConfig']['PortBindings']["#{psplit[1]}/tcp"] = [{ "HostPort": "#{psplit[0]}" }]
      end
    end
    # puts "container options:"
    # p coptions
    if !Docker::Image.exist?(image)
      puts "Image #{image} doesn't exist, pulling..."
      # Pull image to make sure we have it.
      di = Docker::Image.create('fromImage' => image)
      # Temporary hack until docker gem updated: https://github.com/swipely/docker-api/issues/369
      # begin
      #   Docker::Image.create('fromImage' => image_name) do |info|
      #     yield info if block_given?
      #   end
      # rescue Docker::Error::NotFoundError => e
      #   # see: https://github.com/swipely/docker-api/issues/369
      #   # as long as this is not fixed we need to re-check on our own
      #   # on docker-engines >= 1.10
      #   if Gem::Version.new(Docker.version['Version']) >= Gem::Version.new('1.10.0')
      #     Docker::Image.get(image_name)
      #   else
      #     raise e
      #   end
      # end
    end
    # END HACK

    # Now fire it up
    container = Docker::Container.create(coptions)
    # Capture ctrl-c
    Signal.trap("INT") {
      # Ctrl-C was pressed...
      puts "Caught interrupt - killing docker child..."

      # Kill child process...
      # p `docker kill #{cname}`
      # Process.kill("INT", pid)
      container.delete(:force=>true)
      exit 0

      # This prevents the process from becoming defunct
      # oe.close
    }
    container.tap(&:start).streaming_logs(follow:true, stdout: true, stderr: true) { |stream, chunk|
      # puts "#{stream}: #{chunk}" # for debugging
      puts chunk
    }
    # puts "Deleting container"
    container.delete(:force => true)
  end

  def self.popen(maincmd, cname)
    Open3.popen2e('docker', *(maincmd)) {|i,oe,t|
      pid = t.pid # pid of the started process.
      # puts "pid: #{pid}"
      i.close # ensure this exits when it's done with output

      # Catch interrupts to shut down the docker process too
      Signal.trap("INT") {
        # Ctrl-C was pressed...
        puts "Caught interrupt - killing docker child..."

        # Kill child process...
        p `docker kill #{cname}`
        # Process.kill("INT", pid)

        # This prevents the process from becoming defunct
        # oe.close
      }

      begin
        oe.each {|line|
          if /warning/ =~ line
            puts 'warning'
          end
          puts line
        }
      rescue IOError => ex
        # ignore?  closed stream probably
      end
      oe.close
      exit_status = t.value # Process::Status object returned.
      # puts "exit_status: #{exit_status}"
    }
  end

  def self.exec(cmd, args = [])
    split = cmd.split(' ')
    DockerJockey.logger.debug "Exec: #{(split + args).join(' ')}"
    base = split.shift
    Open3.popen2e(base, *(split + args)) {|i,oe,t|
      pid = t.pid # pid of the started process.
      i.close # ensure this exits when it's done with output
      oe.each {|line|
        if /warning/ =~ line
          puts 'warning'
        end
        puts line
      }
      exit_status = t.value # Process::Status object returned.
      # puts "exit_status: #{exit_status}"
    }
  end

end
