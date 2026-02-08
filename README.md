# Neocities Red

Hello, there is a fork of [neocities-ruby gem](https://github.com/neocities/neocities-ruby) with my own features and implementations. A much of my changes doesn't make sense to be pushed into original repository, so i pushed it here.

## Main changes/Features:

### Currently, this gems tests with ruby 3.4.*, it doesn't supports ruby 4 due of dependencies

1) Added MultiThread uploading of files to neocities. This feature boosts `neocities push`;
2) Moves from `http.rb` to `faraday` gem;
3) Fixed `-e` flag to exclude folders recursively;
4) Added `--ignore-dotfiles` to ignore all files-folders starts with '.';
5) Added `--optimized` for `neocities push` flag to upload only modified files;
6) Fixed bug with neocities info on modern rubies;
7) Re-designed `upload` method logic;
8) upload method also could upload folders with their content;

## TODO'S:
1) Check all entire cli and client logic, fix bugs.
2) Change dependencies for modern analogs.
3) Refactor `cli.rb` or use `rails/thor` gem instead.
4) Add tests
5) Make sure that gem is compatible with Linux, Freebsd, Windows
6) Make it compatible with ruby 4.0.0

# The Neocities Gem

A CLI and library for using the Neocities API. Makes it easy to quickly upload, push, delete, and list your Neocities site.

## Installation

```
  gem install neocities-red
```

### Running

After that, you are all set! Run `neocities-red` in a command line to see the options and get started.

## Gem modules

This gem also transpose all processes to several class in lib/neocities, which could be used to write code that interfaces with the Neocities API.

```ruby
require 'neocities-red'

# use api key
params = {
  api_key: 'MyKeyFromNeocities'
}

# or sitename and password
# params = {
#  sitename: 'petrapixel,
#  password: 'mypass'
# }

client = Neocities::Client.new(params)
client.key
client.upload(path, remote_path)
client.info(sitename)
client.delete(path)
client.push(path)
client.list(path)
```

# Contributions ..?

I'm glad to see everyone, so for contribution you need to check issues and take one typing something like "i'd like to take this issue". After that you should to make fork of this repository, create new branch and complete the task. 

If there are no tasks, just ping me (o-200) at the new issue, and we will think about what can be implemented or fixed.
