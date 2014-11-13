fs = require "fs"
spawn = require("child_process").spawn
exec = require("child_process").exec
rimraf = require "rimraf"
Path = require "path"
semver = require "semver"
knox = require "knox"
crypto = require "crypto"
async = require "async"

SERVICES = [{
	name: "web"
	repo: "https://github.com/watercrossing/web-sharelatex.git"
	version: "UCLLive"
}, {
	name: "document-updater"
	repo: "https://github.com/sharelatex/document-updater-sharelatex.git"
	version: "v0.1.0"
}, {
	name: "clsi"
	repo: "https://github.com/sharelatex/clsi-sharelatex.git"
	version: "v0.1.1"
}, {
	name: "filestore"
	repo: "https://github.com/sharelatex/filestore-sharelatex.git"
	version: "v0.1.0"
}, {
	name: "track-changes"
	repo: "https://github.com/sharelatex/track-changes-sharelatex.git"
	version: "v0.1.0"
}, {
	name: "docstore"
	repo: "https://github.com/sharelatex/docstore-sharelatex.git"
	version: "v0.1.0"
}, {
	name: "chat"
	repo: "https://github.com/sharelatex/chat-sharelatex.git"
	version: "v0.1.0"
}, {
	name: "tags"
	repo: "https://github.com/sharelatex/tags-sharelatex.git"
	version: "v0.1.0"
}, {
	name: "spelling"
	repo: "https://github.com/sharelatex/spelling-sharelatex.git"
	version: "v0.1.0"
}]

module.exports = (grunt) ->
	grunt.loadNpmTasks 'grunt-bunyan'
	grunt.loadNpmTasks 'grunt-execute'
	grunt.loadNpmTasks 'grunt-available-tasks'
	grunt.loadNpmTasks 'grunt-concurrent'

	execute = {}
	for service in SERVICES
		execute[service.name] =
			src: "#{service.name}/app.js"

	grunt.initConfig
		execute: execute

		concurrent:
			all:
				tasks: ("run:#{service.name}" for service in SERVICES)
				options:
					limit: SERVICES.length
					logConcurrentOutput: true

		availabletasks:
			tasks:
				options:
					filter: 'exclude',
					tasks: [
						'concurrent'
						'execute'
						'bunyan'
						'availabletasks'
						]
					groups:
						"Run tasks": [
							"run"
							"run:all"
							"default"
						].concat ("run:#{service.name}" for service in SERVICES)
						"Misc": [
							"help"
						]
						"Install tasks": ("install:#{service.name}" for service in SERVICES).concat(["install:all", "install", "install:dirs", "install:config"])
						"Update tasks": ("update:#{service.name}" for service in SERVICES).concat(["update:all", "update"])
						"Config tasks": ["install:config"]
						"Checks": ["check", "check:redis", "check:latexmk", "check:s3", "check:make"]

	for service in SERVICES
		do (service) ->
			grunt.registerTask "install:#{service.name}", "Download and set up the #{service.name} service", () ->
				done = @async()
				Helpers.installService(service, done)
			grunt.registerTask "update:#{service.name}", "Checkout and update the #{service.name} service", () ->
				done = @async()
				Helpers.updateService(service, done)
			grunt.registerTask "run:#{service.name}", "Run the ShareLaTeX #{service.name} service", ["bunyan", "execute:#{service.name}"]
			grunt.registerTask "release:#{service.name}", "Create a new release version of #{service.name} (specify with --release option)", () ->
				done = @async()
				Helpers.createNewRelease(service, grunt.option("release"), done)

	grunt.registerTask 'install:config', "Copy the example config into the real config", () ->
		Helpers.installConfig @async()
	grunt.registerTask 'install:dirs', "Copy the example config into the real config", () ->
		Helpers.createDataDirs @async()
	grunt.registerTask 'install:all', "Download and set up all ShareLaTeX services",
		["check:make"].concat(
			("install:#{service.name}" for service in SERVICES)
		).concat(["install:config", "install:dirs"])
	grunt.registerTask 'install', 'install:all'
	grunt.registerTask 'update:all', "Checkout and update all ShareLaTeX services",
		["check:make"].concat(
			("update:#{service.name}" for service in SERVICES)
		)
	grunt.registerTask 'update', 'update:all'
	grunt.registerTask 'run', "Run all of the sharelatex processes", ['concurrent:all']
	grunt.registerTask 'run:all', 'run'

	grunt.registerTask 'help', 'Display this help list', 'availabletasks'
	grunt.registerTask 'default', 'run'

	grunt.registerTask "check:redis", "Check that redis is installed and running", () ->
		Helpers.checkRedis @async()
	grunt.registerTask "check:latexmk", "Check that latexmk is installed", () ->
		Helpers.checkLatexmk @async()
	grunt.registerTask "check:s3", "Check that Amazon S3 credentials are configured", () ->
		Helpers.checkS3 @async()
	grunt.registerTask "check:fs", "Check that local filesystem options are configured", () ->
		Helpers.checkFS @async()
	grunt.registerTask "check:aspell", "Check that aspell is installed", () ->
		Helpers.checkAspell @async()
	grunt.registerTask "check:make", "Check that make is installed", () ->
		Helpers.checkMake @async()
	grunt.registerTask "check", "Check that you have the required dependencies installed", ["check:redis", "check:latexmk", "check:s3", "check:fs", "check:aspell"]

	grunt.registerTask "build:deb", "Build an installable .deb file from the current directory", () ->
		Helpers.buildDeb @async()
	grunt.registerTask "build:upstart_scripts", "Create upstart scripts for each service", () ->
		Helpers.buildUpstartScripts()

	Helpers =
		installService: (service, callback = (error) ->) ->
			Helpers.cloneGitRepo service, (error) ->
				return callback(error) if error?
				Helpers.installNpmModules service, (error) ->
					return callback(error) if error?
					Helpers.runGruntInstall service, (error) ->
						return callback(error) if error?
						callback()

		updateService: (service, callback = (error) ->) ->
			Helpers.updateGitRepo service, (error) ->
				return callback(error) if error?
				Helpers.installNpmModules service, (error) ->
					return callback(error) if error?
					Helpers.runGruntInstall service, (error) ->
						return callback(error) if error?
						callback()

		cloneGitRepo: (service, callback = (error) ->) ->
			repo_src = service.repo
			dir = service.name
			if !fs.existsSync(dir)
				proc = spawn "git", [
					"clone",
					"-b", service.version,
					repo_src,
					dir
				], stdio: "inherit"
				proc.on "close", () ->
					callback()
			else
				console.log "#{dir} already installed, skipping."
				callback()

		updateGitRepo: (service, callback = (error) ->) ->
			dir = service.name
			proc = spawn "git", ["checkout", service.version], cwd: dir, stdio: "inherit"
			proc.on "close", () ->
				proc = spawn "git", ["pull"], cwd: dir, stdio: "inherit"
				proc.on "close", () ->
					callback()
					
		createNewRelease: (service, version, callback = (error) ->) ->
			dir = service.name
			proc = spawn "sed", [
				"-i", "",
				"s/\"version\".*$/\"version\": \"#{version}\",/g",
				"package.json"
			], cwd: dir, stdio: "inherit"
			proc.on "close", () ->
				proc = spawn "git", ["commit", "-a", "-m", "Release version #{version}"], cwd: dir, stdio: "inherit"
				proc.on "close", () ->
					proc = spawn "git", ["tag", "v#{version}"], cwd: dir, stdio: "inherit"
					proc.on "close", () ->
						proc = spawn "git", ["push"], cwd: dir, stdio: "inherit"
						proc.on "close", () ->
							proc = spawn "git", ["push", "--tags"], cwd: dir, stdio: "inherit"
							proc.on "close", () ->
								callback()
								
		installNpmModules: (service, callback = (error) ->) ->
			dir = service.name
			proc = spawn "npm", ["install"], stdio: "inherit", cwd: dir
			proc.on "close", () ->
				callback()
				
		createDataDirs: (callback = (error) ->) ->
			DIRS = [
				"tmp/dumpFolder"
				"tmp/uploads"
				"data/user_files"
				"data/compiles"
				"data/cache"
			]
			jobs = []
			for dir in DIRS
				do (dir) ->
					jobs.push (callback) ->
						path = Path.join(__dirname, dir)
						grunt.log.writeln "Ensuring '#{path}' exists"
						exec "mkdir -p #{path}", callback
			async.series jobs, callback

		installConfig: (callback = (error) ->) ->
			src = "config/settings.development.coffee.example"
			dest = "config/settings.development.coffee"
			if !fs.existsSync(dest)
				grunt.log.writeln "Creating config at #{dest}"
				config = fs.readFileSync(src).toString()
				config = config.replace /CRYPTO_RANDOM/g, () ->
					crypto.randomBytes(64).toString("hex")
				fs.writeFileSync dest, config
				callback()
			else
				grunt.log.writeln "Config file already exists. Skipping."
				callback()

		runGruntInstall: (service, callback = (error) ->) ->
			dir = service.name
			proc = spawn "grunt", ["install"], stdio: "inherit", cwd: dir
			proc.on "close", () ->
				callback()

		checkRedis: (callback = (error) ->) ->
			grunt.log.write "Checking Redis is running... "
			exec "redis-cli info", (error, stdout, stderr) ->
				if error? and error.message.match("Could not connect")
					grunt.log.error "FAIL. Redis is not running"
					return callback(error)
				else if error?
					return callback(error)
				else
					m = stdout.match(/redis_version:(.*)/)
					if !m?
						grunt.log.error "FAIL."
						grunt.log.error "Unknown redis version"
						error = new Error("Unknown redis version")
					else
						version = m[1]
						if semver.gte(version, "2.6.12")
							grunt.log.writeln "OK."
							grunt.log.writeln "Running Redis version #{version}"
						else
							grunt.log.error "FAIL."
							grunt.log.error "Redis version is too old (#{version}). Must be 2.6.12 or greater."
							error = new Error("Redis version is too old (#{version}). Must be 2.6.12 or greater.")
				callback(error)

		checkLatexmk: (callback = (error) ->) ->
			grunt.log.write "Checking latexmk is installed... "
			exec "latexmk --version", (error, stdout, stderr) ->
				if error? and error.message.match("not found")
					grunt.log.error "FAIL."
					grunt.log.errorlns """
					Either latexmk is not installed or is not in your PATH.

					latexmk comes with TexLive 2013, and must be a version from 2013 or later.
					If you have already have TeXLive installed, then make sure it is
					included in your PATH (example for 64-bit linux):
					
						export PATH=$PATH:/usr/local/texlive/2014/bin/x86_64-linux/
					
					This is a not a fatal error, but compiling will not work without latexmk.
					"""
					return callback(error)
				else if error?
					return callback(error)
				else
					m = stdout.match(/Version (.*)/)
					if !m?
						grunt.log.error "FAIL."
						grunt.log.error "Unknown latexmk version"
						error = new Error("Unknown latexmk version")
					else
						version = m[1]
						if semver.gte(version + ".0", "4.39.0")
							grunt.log.writeln "OK."
							grunt.log.writeln "Running latexmk version #{version}"
						else
							grunt.log.error "FAIL."
							grunt.log.errorlns """
							latexmk version is too old (#{version}). Must be 4.39 or greater.
							This is a not a fatal error, but compiling will not work without latexmk
							"""
							error = new Error("latexmk is too old")
				callback(error)
				
		checkAspell: (callback = (error) ->) ->
			grunt.log.write "Checking aspell is installed... "
			exec "aspell dump dicts", (error, stdout, stderr) ->
				if error? and error.message.match("not found")
					grunt.log.error "FAIL."
					grunt.log.errorlns """
					Either aspell is not installed or is not in your PATH.
					
					On Ubuntu you can install aspell with:
					
						sudo apt-get install aspell
						
					Or on a mac:
					
						brew install aspell
						
					This is not a fatal error, but the spell-checker will not work without aspell
					"""
					return callback(error)
				else if error?
					return callback(error)
				else
					grunt.log.writeln "OK."
					grunt.log.writeln "The following spell check dictionaries are available:"
					grunt.log.write stdout
					callback()
				callback(error)

		checkS3: (callback = (error) ->) ->
			Settings = require "settings-sharelatex"
			if Settings.filestore.backend==""
				grunt.log.writeln "No backend specified. Assuming Amazon S3"
				Settings.filestore.backend = "s3"
			if Settings.filestore.backend=="s3"
				grunt.log.write "Checking S3 credentials... "
				try
					client = knox.createClient({
						key: Settings.filestore.s3.key
						secret: Settings.filestore.s3.secret
						bucket: Settings.filestore.stores.user_files
					})
				catch e
					grunt.log.error "FAIL."
					grunt.log.errorlns """
					Please configure your Amazon S3 credentials in config/settings.development.coffee

					Amazon S3 (Simple Storage Service) is a cloud storage service provided by
					Amazon. ShareLaTeX uses S3 for storing binary files like images. You can 
					sign up for an account and find out more at:

							http://aws.amazon.com/s3/
										
					"""
					return callback()
				client.getFile "does-not-exist", (error, response) ->
					unless response? and response.statusCode == 404
						grunt.log.error "FAIL."
						grunt.log.errorlns """
						Could not connect to Amazon S3. Please check your credentials.
						"""
					else
						grunt.log.writeln "OK."
					callback()
			else
				grunt.log.writeln "Filestore other than S3 configured. Not checking S3."
				callback()

		checkFS: (callback = (error) ->) ->
			Settings = require "settings-sharelatex"
			if Settings.filestore.backend=="fs"
				grunt.log.write "Checking FS configuration... "
				fs = require("fs")
				fs.exists Settings.filestore.stores.user_files, (exists) ->
					if exists
						grunt.log.writeln "OK."
					else
						grunt.log.error "FAIL."
						grunt.log.errorlns """
						Could not find directory "#{Settings.filestore.stores.user_files}". 
						Please check your configuration.
						"""
					callback()
			else
				grunt.log.writeln "Filestore other than FS configured. Not checking FS."
				callback()

		checkMake: (callback = (error) ->) ->
			grunt.log.write "Checking make is installed... "
			exec "make --version", (error, stdout, stderr) ->
				if error? and error.message.match("not found")
					grunt.log.error "FAIL."
					grunt.log.errorlns """
					Either make is not installed or is not in your path.
					
					On Ubuntu you can install make with:
					
					    sudo apt-get install build-essential
					
					"""
					return callback(error)
				else if error?
					return callback(error)
				else
					grunt.log.write "OK."
					return callback()

		buildUpstartScripts: () ->
			template = fs.readFileSync("package/upstart/sharelatex-template").toString()
			for service in SERVICES
				fs.writeFileSync "package/upstart/sharelatex-#{service.name}", template.replace(/__SERVICE__/g, service.name)

		buildPackageSettingsFile: () ->
			config = fs.readFileSync("config/settings.development.coffee.example").toString()
			config = config.replace /DATA_DIR.*/, "DATA_DIR = '/var/lib/sharelatex/data'"
			config = config.replace /TMP_DIR.*/, "TMP_DIR = '/var/lib/sharelatex/tmp'"
			fs.writeFileSync "package/config/settings.coffee", config

		buildDeb: (callback = (error) ->) ->
			command = ["-s", "dir", "-t", "deb", "-n", "sharelatex", "-v", "0.0.1", "--verbose"]
			command.push(
				"--maintainer", "ShareLaTeX <team@sharelatex.com>"
				"--config-files", "/etc/sharelatex/settings.coffee"
				"--config-files", "/etc/nginx/conf.d/sharelatex.conf"
				"--directories",  "/var/lib/sharelatex"
				"--directories",  "/var/log/sharelatex"
			)

			command.push(
				"--depends", "redis-server > 2.6.12"
				"--depends", "mongodb-org > 2.4.0"
				"--depends", "nodejs > 0.10.0"
			)
			
			@buildPackageSettingsFile()

			@buildUpstartScripts()
			for service in SERVICES
				command.push(
					"--deb-upstart", "package/upstart/sharelatex-#{service.name}"
				)

			after_install_script = """
				#!/bin/sh
				# Create random secret keys (twice, once for http auth pass, once for cookie secret).
				sed -i "0,/CRYPTO_RANDOM/s/CRYPTO_RANDOM/$(cat /dev/urandom | tr -dc 'a-z0-9' | fold -w 64 | head -n 1)/" /etc/sharelatex/settings.coffee
				sed -i "0,/CRYPTO_RANDOM/s/CRYPTO_RANDOM/$(cat /dev/urandom | tr -dc 'a-z0-9' | fold -w 64 | head -n 1)/" /etc/sharelatex/settings.coffee
				
				sudo adduser --system --group --home /var/www/sharelatex --no-create-home sharelatex

				mkdir -p /var/log/sharelatex
				chown sharelatex:sharelatex /var/log/sharelatex
				
				mkdir -p /var/lib/sharelatex

			"""

			for dir in ["data/user_files", "tmp/uploads", "data/compiles", "data/cache", "tmp/dumpFolder"]
				after_install_script += """
					mkdir -p /var/lib/sharelatex/#{dir}
					
				"""
			
			after_install_script += """
				chown -R sharelatex:sharelatex /var/lib/sharelatex
				
			"""	

			for service in SERVICES
				after_install_script += "service sharelatex-#{service.name} restart\n"
			fs.writeFileSync "package/scripts/after_install.sh", after_install_script
			command.push("--after-install", "package/scripts/after_install.sh")

			command.push("--exclude", "**/.git")
			command.push("--exclude", "**/node_modules/grunt-*")
			for path in ["filestore/user_files", "filestore/uploads", "clsi/cache", "clsi/compiles"]
				command.push "--exclude", path

			for service in SERVICES
				command.push "#{service.name}=/var/www/sharelatex/"

			command.push(
				"package/config/settings.coffee=/etc/sharelatex/settings.coffee"
				"package/nginx/sharelatex=/etc/nginx/conf.d/sharelatex.conf"
			)
			console.log "fpm " + command.join(" ")
			proc = spawn "fpm", command, stdio: "inherit"
			proc.on "close", (code) ->
				if code != 0
					callback(new Error("exit code: #{code}"))
				else
					callback()

			




