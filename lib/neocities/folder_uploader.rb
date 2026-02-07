# frozen_string_literal: true

require 'pathname'
require 'pastel'

module Neocities
  class FileIsNotExists < StandardError; end

  class FolderUploader
    def initialize(client, filepath, remote_path = nil)
      @client = client
      @filepath = filepath
      @remote_path = remote_path
      @pastel = Pastel.new(eachline: "\n")
    end

    def upload
      path = Pathname(@filepath)

      raise FileIsNotExists, "#{path} does not exist locally." unless path.exist?

      if path.file?
        puts @pastel.bold("#{path} is not a directory, skipping")
        return
      end

      Dir.chdir(path) do
        files = Dir.glob('**', File::FNM_DOTMATCH)[1..]
        files.each do |file|
          remote_path = File.join(@remote_path, file)
          FileUploader.new(@client, file, remote_path).upload
        end
      end
    end
  end
end
