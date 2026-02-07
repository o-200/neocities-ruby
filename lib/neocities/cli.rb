# frozen_string_literal: true

require 'pathname'
require 'pastel'
require 'tty/table'
require 'tty/prompt'
require 'fileutils'
require 'json'
require 'whirly'
require 'digest'
require 'time'

# warning - the big quantity of working threads could be considered like-a DDOS. Your ip-address could get banned for a few days.
MAX_THREADS = 5

module Neocities
  class CLI
    SUBCOMMANDS = %w[upload delete list info push logout pizza pull purge].freeze
    HELP_SUBCOMMANDS = ['-h', '--help', 'help'].freeze
    PENELOPE_MOUTHS = %w[^ o ~ - v U].freeze
    PENELOPE_EYES = %w[o ~ O].freeze

    def initialize(argv)
      @argv = argv.dup
      @pastel = Pastel.new eachline: "\n"
      @subcmd = @argv.first
      @subargs = @argv[1..@argv.length]
      @prompt = TTY::Prompt.new
      @api_key = ENV['NEOCITIES_API_KEY'] || nil
      @app_config_path = File.join self.class.app_config_path('neocities'), 'config.json'
    end

    def display_response(resp)
      if resp.is_a?(Exception)
        out = "#{@pastel.red.bold 'ERROR:'} #{resp.detailed_message}"
        puts out
        exit
      end

      if resp[:result] == 'success'
        puts "#{@pastel.green.bold 'SUCCESS:'} #{resp[:message]}"
      elsif resp[:result] == 'error' && resp[:error_type] == 'file_exists'
        out = "#{@pastel.yellow.bold 'EXISTS:'} #{resp[:message]}"
        out += " (#{resp[:error_type]})" if resp[:error_type]
        puts out
      else
        out = "#{@pastel.red.bold 'ERROR:'} #{resp[:message]}"
        out += " (#{resp[:error_type]})" if resp[:error_type]
        puts out
      end
    end

    def run
      if @argv[0] == 'version'
        puts Neocities::VERSION
        exit
      end

      if HELP_SUBCOMMANDS.include?(@subcmd) && SUBCOMMANDS.include?(@subargs[0])
        send "display_#{@subargs[0]}_help_and_exit"
      elsif @subcmd.nil? || !SUBCOMMANDS.include?(@subcmd)
        display_help_and_exit
      elsif @subargs.join('').match(HELP_SUBCOMMANDS.join('|')) && @subcmd != 'info'
        send "display_#{@subcmd}_help_and_exit"

      end

      unless @api_key
        begin
          file = File.read @app_config_path
          data = JSON.parse file

          if data
            @api_key = data['API_KEY'].strip
            @sitename = data['SITENAME']
            @last_pull = data['LAST_PULL'] # Store the last time a pull was performed so that we only fetch from updated files
          end
        rescue Errno::ENOENT
          @api_key = nil
        end
      end

      if @api_key.nil?
        puts 'Please login to get your API key:'

        if !@sitename && !@password
          @sitename = @prompt.ask('sitename:', default: ENV['NEOCITIES_SITENAME'])
          @password = @prompt.mask('password:', default: ENV['NEOCITIES_PASSWORD'])
        end

        @client = Neocities::Client.new sitename: @sitename, password: @password

        resp = @client.key
        if resp[:api_key]
          conf = {
            "API_KEY": resp[:api_key],
            "SITENAME": @sitename
          }

          FileUtils.mkdir_p Pathname(@app_config_path).dirname
          File.write @app_config_path, conf.to_json

          puts "The api key for #{@pastel.bold @sitename} has been stored in #{@pastel.bold @app_config_path}."
        else
          display_response resp
          exit
        end
      else
        @client = Neocities::Client.new api_key: @api_key
      end

      send @subcmd
    end

    def delete
      display_delete_help_and_exit if @subargs.empty?

      @subargs.each do |path|
        FileRemover.new(@client, path).remove
      end
    end

    def logout
      confirmed = false

      loop do
        case @subargs[0]
        when '-y'
          @subargs.shift
          confirmed = true
        when /^-/
          puts @pastel.red.bold("Unknown option: #{@subargs[0].inspect}")
          break
        else
          break
        end
      end

      if confirmed
        FileUtils.rm @app_config_path
        puts @pastel.bold('Your api key has been removed.')
      else
        display_logout_help_and_exit
      end
    end

    def info
      profile_info = ProfileInfo.new(@client, @subargs, @sitename).pretty_print
      puts TTY::Table.new(profile_info)
    rescue Exception => e
      display_response(e)
    end

    def list
      display_list_help_and_exit if @subargs.empty?

      @detail = true if @subargs.delete('-d') == '-d'

      @subargs[0] = nil if @subargs.delete('-a')

      path = @subargs[0]

      FileList.new(@client, path, @detail).show
    end

    def push
      display_push_help_and_exit if @subargs.empty?
      @no_gitignore = false
      @ignore_dotfiles = false
      @excluded_files = []
      @dry_run = false
      @prune = false
      @optimized = false

      loop do
        case @subargs[0]
        when '--no-gitignore'
          @subargs.shift
          @no_gitignore = true
        when '--ignore-dotfiles'
          @subargs.shift
          @ignore_dotfiles = true
        when '-e'
          @subargs.shift
          filepath = Pathname.new(@subargs.shift).cleanpath.to_s

          if File.file?(filepath)
            @excluded_files.push(filepath)
          elsif File.directory?(filepath)
            folder_files = Dir.glob(File.join(filepath, '**', '*'), File::FNM_DOTMATCH).push(filepath)
            @excluded_files += folder_files
          end
        when '--dry-run'
          @subargs.shift
          @dry_run = true
        when '--prune'
          @subargs.shift
          @prune = true
        when '--optimized'
          @subargs.shift
          @optimized = true
        when /^-/
          puts @pastel.red.bold("Unknown option: #{@subargs[0].inspect}")
          display_push_help_and_exit
        else
          break
        end
      end

      if @subargs[0].nil?
        display_response result: 'error', message: 'no local path provided'
        display_push_help_and_exit
      end

      root_path = Pathname @subargs[0]

      unless root_path.exist?
        display_response result: 'error', message: "path #{root_path} does not exist"
        display_push_help_and_exit
      end

      unless root_path.directory?
        display_response result: 'error', message: 'provided path is not a directory'
        display_push_help_and_exit
      end

      puts @pastel.green.bold('Doing a dry run, not actually pushing anything') if @dry_run

      if @prune
        pruned_dirs = []
        resp = @client.list
        resp[:files].each do |file|
          path = Pathname(File.join(@subargs[0], file[:path]))

          pruned_dirs << path if !path.exist? && file[:is_directory]

          next unless !path.exist? && !pruned_dirs.include?(path.dirname)

          print @pastel.bold("Deleting #{file[:path]} ... ")
          resp = @client.delete_wrapper_with_dry_run file[:path], @dry_run

          if resp[:result] == 'success'
            print "#{@pastel.green.bold('SUCCESS')}\n"
          else
            print "\n"
            display_response resp
          end
        end
      end

      Dir.chdir(root_path) do
        paths = Dir.glob(File.join('**', '*'), File::FNM_DOTMATCH)

        if @no_gitignore == false
          begin
            ignores = File.readlines('.gitignore').collect! do |ignore|
              ignore.strip!
              File.directory?(ignore) ? "#{ignore}**" : ignore
            end
            paths.select! do |path|
              res = true
              ignores.each do |ignore|
                if File.fnmatch?(ignore.strip, path)
                  res = false
                  break
                end
              end
            end
            puts 'Not pushing .gitignore entries (--no-gitignore to disable)'
          rescue Errno::ENOENT
          end
        end

        @excluded_files += paths.select { |path| path.start_with?('.') } if @ignore_dotfiles

        # do not upload files which already uploaded (checking by sha1_hash)
        if @optimized
          hex = paths.select { |path| File.file?(path) }
                     .map { |file| { filepath: file, sha1_hash: Digest::SHA1.file(file).hexdigest } }

          res = @client.list
          server_hex = res[:files].map { |n| n[:sha1_hash] }.compact

          uploaded_files = hex.select { |n| server_hex.include?(n[:sha1_hash]) }
                              .map { |n| n[:filepath] }
          @excluded_files += uploaded_files
        end

        paths -= @excluded_files
        paths.collect! { |path| Pathname path }

        task_queue = Queue.new
        paths.each { |path| task_queue.push(path) }

        threads = []

        MAX_THREADS.times do
          threads << Thread.new do
            until task_queue.empty?
              path = begin
                task_queue.pop(true)
              rescue StandardError
                nil
              end
              next if path.nil? || path.directory?

              Neocities::FileUploader.new(@client, path, path).upload
            end
          end
        end

        threads.each(&:join)
        puts 'All files uploaded.'
      end
    end

    def upload
      display_upload_help_and_exit if @subargs.empty?

      loop do
        case @subargs[0]
        when /^-/
          puts @pastel.red.bold("Unknown option: #{@subargs[0].inspect}")
          display_upload_help_and_exit
        else
          break
        end
      end

      if File.file?(@subargs[0])
        FileUploader.new(@client, @subargs[0], @subargs[1]).upload
      elsif File.directory?(@subargs[0])
        FolderUploader.new(@client, @subargs[0], @subargs[1]).upload
      end
    end

    def pull
      quiet = ['--quiet', '-q'].include?(@subargs[0])
      file = File.read(@app_config_path)
      data = JSON.parse(file)
      last_pull_time = data['LAST_PULL']['time']
      last_pull_loc = data['LAST_PULL']['loc']

      SiteExporter.new(@client, @sitename, data, @app_config_path)
                  .export(quiet, last_pull_time, last_pull_loc)
    end

    # only for development purposes
    def purge
      pruned_dirs = []
      resp = @client.list
      resp[:files].each do |file|
        print @pastel.bold("Deleting #{file[:path]} ... ")
        resp = @client.delete_wrapper_with_dry_run file[:path], @dry_run

        if resp[:result] == 'success'
          print "#{@pastel.green.bold('SUCCESS')}\n"
        else
          print "\n"
          display_response resp
        end
      end
    end

    def pizza
      display_pizza_help_and_exit
    end

    def display_pizza_help_and_exit
      puts Pizza.new.make_order
    end

    def display_list_help_and_exit
      display_banner

      puts <<HERE
  #{@pastel.green.bold 'list'} - List files on your Neocities site

  #{@pastel.dim 'Examples:'}

  #{@pastel.green '$ neocities list /'}           List files in your root directory

  #{@pastel.green '$ neocities list -a'}          Recursively display all files and directories

  #{@pastel.green '$ neocities list -d /mydir'}   Show detailed information on /mydir

HERE
      exit
    end

    def display_delete_help_and_exit
      display_banner

      puts <<HERE
  #{@pastel.green.bold 'delete'} - Delete files on your Neocities site

  #{@pastel.dim 'Examples:'}

  #{@pastel.green '$ neocities delete myfile.jpg'}               Delete myfile.jpg

  #{@pastel.green '$ neocities delete myfile.jpg myfile2.jpg'}   Delete myfile.jpg and myfile2.jpg

  #{@pastel.green '$ neocities delete mydir'}                    Deletes mydir and everything inside it (be careful!)

HERE
      exit
    end

    def display_upload_help_and_exit
      display_banner

      puts <<HERE
  #{@pastel.green.bold 'upload'} - Upload file to your Neocities site to the specific path

  #{@pastel.dim 'Examples:'}

  #{@pastel.green '$ neocities upload /img.jpg /images/img2.jpg'} Upload img.jpg to /images folder and with img2.jpg name
HERE
      exit
    end

    def display_pull_help_and_exit
      display_banner

      puts <<HERE
  #{@pastel.magenta.bold 'pull'} - Get the most recent version of files from your site, does not download if files haven't changed

HERE
      exit
    end

    def display_push_help_and_exit
      display_banner

      puts <<HERE
  #{@pastel.green.bold 'push'} - Recursively upload a local directory to your Neocities site

  #{@pastel.dim 'Examples:'}

  #{@pastel.green '$ neocities push .'}                                 Recursively upload current directory.

  #{@pastel.green '$ neocities push -e node_modules -e secret.txt .'}   Exclude certain files from push

  #{@pastel.green '$ neocities push --no-gitignore .'}                  Don't use .gitignore to exclude files

  #{@pastel.green '$ neocities push --ignore-dotfiles .'}               Ignore files with '.' at the beginning (for example, '.git/')

  #{@pastel.green '$ neocities push --dry-run .'}                       Just show what would be uploaded

  #{@pastel.green '$ neocities push --optimized .'}                      Do not upload unchanged files.#{' '}

  #{@pastel.green '$ neocities push --prune .'}                         Delete site files not in dir (be careful!)

HERE
      exit
    end

    def display_info_help_and_exit
      display_banner

      puts <<HERE
  #{@pastel.green.bold 'info'} - Get site info

  #{@pastel.dim 'Examples:'}

  #{@pastel.green '$ neocities info fauux'}   Gets info for 'fauux' site

HERE
      exit
    end

    def display_logout_help_and_exit
      display_banner

      puts <<HERE
  #{@pastel.green.bold 'logout'} - Remove the site api key from the config

  #{@pastel.dim 'Examples:'}

  #{@pastel.green '$ neocities logout -y'}

HERE
      exit
    end

    def display_banner
      puts <<HERE

  |\\---/|
  | #{PENELOPE_EYES.sample}_#{PENELOPE_EYES.sample} |  #{@pastel.on_red.bold ' Neocities red '}
   \\_#{PENELOPE_MOUTHS.sample}_/

HERE
    end

    def display_help_and_exit
      display_banner
      puts <<HERE
  #{@pastel.dim 'Subcommands:'}
    push        Recursively upload a local directory to your site
    upload      Upload individual files to your Neocities site
    delete      Delete files from your Neocities site
    list        List files from your Neocities site
    info        Information and stats for your site
    logout      Remove the site api key from the config
    version     Unceremoniously display version and self destruct
    pull        Get the most recent version of files from your site
    pizza       Order a free pizza

HERE
      exit
    end

    def self.app_config_path(name)
      platform = case RUBY_PLATFORM
                 when /win32/
                   :win32
                 when /darwin/
                   :darwin
                 when /linux/
                   :linux
                 else
                   :unknown
                 end

      case platform
      when :linux
        return File.join(ENV['XDG_CONFIG_HOME'], name) if ENV['XDG_CONFIG_HOME']

        File.join(ENV['HOME'], '.config', name) if ENV['HOME']
      when :darwin
        File.join(ENV['HOME'], 'Library', 'Application Support', name)
      else
        # Windows platform detection is weird, just look for the env variables
        return File.join(ENV['LOCALAPPDATA'], name) if ENV['LOCALAPPDATA']

        return File.join(ENV['USERPROFILE'], 'Local Settings', 'Application Data', name) if ENV['USERPROFILE']

        # Should work for the BSDs
        File.join(ENV['HOME'], ".#{name}") if ENV['HOME']
      end
    end
  end
end
