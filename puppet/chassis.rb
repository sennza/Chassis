require "pathname"
require "yaml"
require "open3"

module Chassis
	@@dir = File.dirname(File.dirname(__FILE__))
	@@extension_dir = File.join(@@dir, 'extensions')
	@@extension_config = {}

	def self.get_extension_config(extension, base_dir = @@extension_dir)
		# Use cache if we can.
		return @@extension_config[extension] if @@extension_config.key?(extension)

		path = File.join(base_dir, extension, 'chassis.yaml')

		begin
			YAML.load_file(path)
		rescue Errno::ENOENT
			# No configuration, legacy.
			{ "version" => 1 }
		end
	end

	def self.get_extensions_for_dir(ext_dir, version = nil)
		all = Dir.glob(ext_dir + '/*').map { |directory| File.basename( directory ) }

		# Remove dummy _global if found
		all.delete("_global")

		return all if ! version

		all.select { |extension|
			config = get_extension_config(extension, ext_dir)
			config['version'] == version
		}
	end

	def self.get_extensions(version = nil)
		self.get_extensions_for_dir(@@extension_dir, version)
	end

	def self.get_global_extensions(version = nil)
		global = self.get_extensions_for_dir(File.join(@@extension_dir, '_global'), version)

		# Remove extensions which are installed locally
		regular = self.get_extensions(version)
		global.reject { |item|
			regular.include?( item )
		}
	end

	def self.load_config()
		# Load git-managed configuration
		_config = YAML.load_file(File.join(@@dir, "config.yaml"))
		has_custom_prefix = false

		# Load other configuration files
		config_files = [ "config.local.yaml", "content/config.yaml", "content/config.local.yaml" ]
		config_files.each do |filename|
			path = File.join(@@dir, filename)

			begin
				confvars = YAML.load_file(path)

				if confvars.is_a?(Hash)
					_config.merge!(confvars)

					# Check for prefix.
					has_custom_prefix = true if confvars.has_key? "database" and confvars["database"].has_key? "prefix"
				end
			rescue Errno::ENOENT
				# No overriden YAML found -- that's OK; just use the defaults.
			rescue Psych::SyntaxError => e
				# Syntax error of some sort, probably
				puts "ERROR: Could not load config:\n    #{e.message}"
				exit 1
			end
		end

		unless _config["database"].has_key? "prefix"
			puts "ERROR: database.prefix is required as of 2016-11-25 but was not found."
			raise "Could not load Chassis configuration"
		end

		_config["database"]["has_custom_prefix"] = has_custom_prefix
		return _config
	end

	def self.normalize_config(config)
		config["synced_folders"] = {} unless config["synced_folders"]

		if config["wpdir"]
			puts "WARNING: wpdir is deprecated, use paths.wp instead"
			config["paths"]["wp"] = config["wpdir"]
		end

		if ! config["hosts"][0].include?(".local")
			puts "\e[33mWARNING: The hosts URL does not contain .local. You will need to edit your hosts file for this URL to resolve.\e[0m"
		end

		# Set up the paths as needed
		config["mapped_paths"] = {}
		base = config["paths"]["base"] = File.expand_path(config["paths"]["base"], @@dir)
		base_path = Pathname.new base

		if not base.start_with? @@dir
			# Base isn't under the Chassis directory, so mount it separately
			config["synced_folders"][base] = "/chassis"
			config["mapped_paths"]["base"] = "/chassis"
		else
			rel_path = base_path.relative_path_from( Pathname.new @@dir )
			if rel_path.to_s != "."
				config["mapped_paths"]["base"] = "/vagrant/" + rel_path.to_s
			else
				config["mapped_paths"]["base"] = "/vagrant"
			end
		end

		# Grab each of our expected paths
		["wp", "content"].each do |path|
			begin
				config["paths"][path] = File.expand_path(config["paths"][path], base)
			rescue StandardError => e
				config["paths"][path] = File.expand_path(path, base)
				puts "WARNING: Missing paths.#{path} - Defaulting to #{config["paths"][path]}"
			end

			fullpath = config["paths"][path]

			if not fullpath.start_with? base
				# Directory isn't under our base, so needs to manually be mapped
				config["synced_folders"][fullpath] = "/chassis/#{path}"
				config["mapped_paths"][path] = "/chassis/#{path}"
			else
				rel_path = Pathname.new(fullpath).relative_path_from( base_path )
				if rel_path.to_s != "."
					config["mapped_paths"][path] = config["mapped_paths"]["base"] + "/" + rel_path.to_s
				else
					config["mapped_paths"][path] = config["mapped_paths"]["base"]
				end
			end
		end

		# Cast config as needed
		config["nfs"] = !!config["nfs"]
		config["php"] = config["php"].to_s
		config["machine_name"] = config["machine_name"].to_s
		config["upload_size"] = config["upload_size"].to_s

		return config
	end

	def self.config
		self.normalize_config(self.load_config())
	end

	def self.install_extensions(config)
		if config["version"] >= 3
			# Warn about old extensions.
			config["extensions"].each do |extension|
				if extension.include? "-"
					new_extension = extension.gsub(/-/, '_')
					puts("\e[33mPlease change #{extension} to #{new_extension} in your yaml configuration file. \e[0m")
				end
			end
		end

		# Install extensions listed in config
		if config["extensions"]
			config["extensions"].each { |ext| self.install_extension(ext) }
		end

		# For each of the extensions in our folder, read the extension config and
		# install dependencies, etc for that extension.
		self.get_extensions(2).each do |extension|
			ext_config = self.get_extension_config(extension)

			# If we have dependencies, then install them.
			if ext_config["dependencies"]
				ext_config["dependencies"].each { |ext| self.install_extension(ext) }
			end
		end
	end

	def self.install_extension(extension)
		# Perform checks for various forms of extension definition.
		if extension =~ /^[\w-]+$/ # Chassis official extension, like 'nodejs'.
			repo = 'https://github.com/chassis/' + extension
		elsif extension =~ /^[\w-]+\/[\w-]+$/ # account/repo style.
			repo = 'https://github.com/' + extension
		else
			repo = extension
		end

		renamed_extensions = Array.new
		# We need to add a version to allow for a seamless upgrade to Bionic Beaver.
		if config["version"] >= 3
			# Check for existing extensions that have a hyphen and remove them.
			old_extensions = Dir.glob(@@dir + '/extensions/*')
			old_extensions.each { |extension|
			next unless extension.include? "-"
				# Delete the old extension if it has a hyphen in it.
				FileUtils.remove_dir(extension)
				new_extension = extension.gsub(/-/, '_')
				renamed_extensions << "- #{extension} to #{new_extension}"
			}
		    # Puppet have taken a hard stance on not allowing hyphens in class names.
		    folder = @@dir + '/extensions/' + extension.split('/').last.gsub(/\.git$/, '').gsub(/-/, '_').downcase
		else
		    # Leave extensions as they were for Xenial and below for backwards compatibility.
		    folder = @@dir + '/extensions/' + extension.split('/').last.gsub(/\.git$/, '').downcase
		end

		if ! renamed_extensions.empty?
			puts("\e[33mWe're renaming the following extensions:")
			renamed_extensions.each {|extension|
				puts extension
			}
			puts("\e[0m")
		end

		system("git clone %s %s --recursive" % [repo, Shellwords.escape(folder)] ) unless File.exist?( folder )
	end

	def self.make_relative(base, paths)
		# Convert to relative from Vagrantfile
		base = Pathname.new(base)
		paths.map do |path|
			pathname = Pathname.new(path)
			pathname.relative_path_from(base).to_s
		end
	end

	def self.update_core(config)
		if config["auto_update"]["core"] == true
			puts "\e[32mChecking for Chassis core updates...\e[0m"
			updates = self.updates_check(['core'], @@dir)
			if updates.empty?
				puts "\033[A\e[K"
			else
				self.prompt_for_updates(updates, @@extension_dir, 'core')
			end
		end
	end

	def self.update_submodules(config)
		if config["auto_update"]["submodules"] == true
			puts "\033[A\e[32mChecking for Chassis submodule updates...\e[0m"
			submodules = ['apt','mysql','stdlib','wp']
			directory = File.join(@@dir, 'puppet/modules')
			updates = self.submodule_update_check(submodules, directory)
		end
	end

	def self.update_extensions(config)
		if config["auto_update"]["extensions"] == true
			puts "\033[A\e[32mChecking for Chassis extension updates...\e[0m"
			extensions = Dir.glob(@@extension_dir + '/*').map { |directory| File.basename( directory ) }
			updates = self.updates_check(extensions, @@extension_dir)
			if updates.empty?
				puts "\033[A\r\e[K"
			else
				self.prompt_for_updates(updates, @@extension_dir, 'extensions')
			end
		end
	end

	def self.update_global_extensions(config)
		if config["auto_update"]["global_extensions"] == true
			puts "\033[A\e[32mChecking for Chassis global extension updates...\e[0m"
			global_ext_path = File.join(Dir.home, ".chassis", "extensions")
			global_extensions = Dir.glob(global_ext_path + '/*').map { |directory| File.basename( directory ) }
			updates = self.updates_check(global_extensions, global_ext_path)
			if updates.empty?
				puts "\033[A\r\e[K"
			else
				self.prompt_for_updates(updates, global_ext_path, 'extensions')
			end
		end
	end

	def self.updates_check(folders, directory)
		updates = Array.new
		folders.each do |folder|
			next if folder == 'example'
			if 'core' == folder
				folder = directory
				Dir.chdir(directory)
			elsif
				Dir.chdir(directory + '/' + folder )
			end
			_, _, _ = Open3.capture3("git checkout master")
			_, _, _ = Open3.capture3("git remote update")
			stdout, _, _ = Open3.capture3("git status --porcelain=2 --branch")
			if stdout =~ /^# branch.ab \+\d+ -([1-9]\d*)$/
				updates.push folder
			end
			# The user might've been on another branch before we checked out master so switch back.
			_, _, _ = Open3.capture3("git checkout -")
		end
		return updates
	end

	def self.submodule_update_check(folders, directory)
		stdout, _, _ = Open3.capture3("git submodule status")
		if stdout =~ /(\+)/
			print "\e[0;1mYour Chassis submodules are out of date. This may cause provisioning to fail! Would you like to update them now? [Y/n]: \e[0m"
			auto_update = STDIN.gets.chomp
			if ( auto_update != "n" )
				_, _, _ = Open3.capture3("git submodule update")
				puts "\e[032;1mAll your submodules are up to date!\e[0m\n"
			end
		else
			puts "\033[A\r\e[K"
		end
	end

	def self.prompt_for_updates(updates, directory, context)
		if 'core' == context
			print "\e[0;1mChassis core appears to be out of date. This may cause provisioning to fail! Would you like to update it now? [Y/n]: \e[0m"
			auto_update = STDIN.gets.chomp
			self.do_updates(auto_update, updates, directory)
		elsif 'extensions' == context
			if updates.empty? != true
				if ( updates.count > 1 )
					wording = String.new("extensions appear")
				elsif
					wording = String.new("extension appears")
				end
				print "\e[0;1mThe following Chassis #{wording} to be out of date: " + updates.join(", ") + ". This may cause provisioning to fail! Would you like to update them now? [Y/n]: \e[0m"
				auto_update = STDIN.gets.chomp
				self.do_updates(auto_update, updates, directory)
			elsif
				puts "\e[032;1mAll your extensions are up to date!\e[0m\n"
			end
		else
			print "\e[0;1mThe Chassis submodules appear to be out of date. This may cause provisioning to fail! Would you like to update them now? [Y/n]: \e[0m"
			auto_update = STDIN.gets.chomp
			self.do_updates(auto_update, updates, directory)
		end
	end

	def self.do_updates(prompt, updates, directory)
		if ( prompt != "n" )
			updates.each do |update|
				puts "\e[32mUpdating #{update}...\e[0m"
				Dir.chdir(directory + '/' + update)
				_, _, _ = Open3.capture3("git checkout master && git pull")
				puts "\e[32;1mThe #{update} is now up to date.\e[0m"
			end
		end
	end
end
