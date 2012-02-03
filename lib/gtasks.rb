# encoding: utf-8
require 'oauth2'
require 'open-uri'
require 'webrick'
require 'rack'
require 'uri'
require 'yaml'
require 'json'
require 'awesome_print'
require 'logger'
require 'fileutils'

class GoogleTaskAPI
  public
  class << self
    def default_dat_path
      File.join(ENV['HOME'], ".google_tasks.yml")
    end

    def default_callback_uri
      scheme = "http"
      hostname = `hostname`.chomp
      port = 9999
      callback = '/oauth_callback'

      base_url = "#{scheme}://#{hostname}:#{port}"
      URI.join(base_url, callback).to_s
    end
  end

  def initialize(options={})
    @client_id = options[:client_id] or raise ArgumentError.new
    @client_secret = options[:client_secret] or raise ArgumentError.new
    @logger = options[:logger] ||= Logger.new(nil)
    @callback_uri = options[:callback_uri] ||= GoogleTaskAPI::default_callback_uri
    @no_refresh = options[:no_refresh] ||= false

    @client = OAuth2::Client.new(
      @client_id, 
      @client_secret, 
      :site => 'https://www.googleapis.com/',
      :authorize_url => 'https://accounts.google.com/o/oauth2/auth',
      :token_url => 'https://accounts.google.com/o/oauth2/token')

    refresh_or_auth GoogleTaskAPI.default_dat_path

    if block_given?
      yield self
    end
  end


  def task_list(tasklist_ident='@default')
    @token.get("/tasks/v1/lists/#{tasklist_ident}/tasks").parsed
  end

  def task_get(tasklist_ident, task_ident)
    @token.get("/tasks/v1/lists/#{tasklist_ident}/tasks/#{task_ident}").parsed
  end

  def task_insert(tasklist_ident, params={})
    @token.post("/tasks/v1/lists/#{tasklist_ident}/tasks"){ |req|
      req.headers["Content-Type"] = "application/json"
      req.body = params.to_json
    }
  end

  def task_update(tasklist_ident, task_ident, opts={})
    task_info = task_get(tasklist_ident, task_ident)
    params = task_info.merge(opts)

    @token.put("/tasks/v1/lists/#{tasklist_ident}/tasks/#{task_ident}"){ |req|
      req.headers["Content-Type"] = "application/json"
      req.body = params.to_json
    }
  end

  def task_delete(tasklist_ident, task_ident)
    @token.delete("/tasks/v1/lists/#{tasklist_ident}/tasks/#{task_ident}")
  end

  ## ORDER系
  def task_move(tasklist_ident, task_ident)
    # TODO
  end

  # 完了済みタスクの全削除
  def task_clear(tasklist_ident)
    @token.post("/tasks/v1/lists/#{tasklist_ident}/clear").parsed
  end

  def tasklist_list(username = '@me')
    @token.get("/tasks/v1/users/#{username}/lists").parsed
  end

  def tasklist_get(username, ident)
    @token.get("/tasks/v1/users/#{username}/lists/#{ident}").parsed
  end

  def tasklist_insert(username, listname)
    @token.post("/tasks/v1/users/#{username}/lists"){ |req|
      req.headers["Content-Type"] = "application/json"
      req.body = {:title => listname}.to_json
    }
  end

  def tasklist_update(username, tasklist_ident, params={})
    info = tasklist_get(username, tasklist_ident)
    params = info.merge(params)

    @token.put("/tasks/v1/users/#{username}/lists/#{tasklist_ident}"){ |req|
      req.headers["Content-Type"] = "application/json"
      req.body = params.to_json
    }
  end

  def tasklist_delete(username, tasklist_ident)
    @token.delete("/tasks/v1/users/#{username}/lists/#{tasklist_ident}")
  end

  def refresh_or_auth(dat_path)
    @dat_path = dat_path
    @logger.info "dat_path is #{@dat_path.inspect}"
    if File.exists? @dat_path
      @logger.info "dat_path already exist"
      load_from_file @dat_path # load access token
      @logger.info "loaded"

      if @token.refresh_token.nil?
        @logger.info "retry auth"
        auth @callback_uri
        @logger.info "successful auth"

        @logger.info "save to #{@dat_path}"
        save_to_file @dat_path
        @logger.info "saved"
      else
        @logger.info "try to refresh"
        refresh @dat_path # refresh and save access token
        @logger.info "successful refresh"
      end
    else
      begin
        @logger.info "try to oauth2 authentication"
        auth @callback_uri # generate access token
        @logger.info "successful oauth2 authentication"

        @logger.info "save to #{@dat_path}"
        save_to_file @dat_path # save token
        @logger.info "saved"
      rescue => ex
        FileUtils.rm @dat_path
        @logger.info "error detect. remove #{@dat_path.inspect}"
        @logger.info "error information: #{ex.inspect}"
      end
    end
  end

  private
  def auth(redirect_uri = GoogleTaskAPI.default_callback_uri)
    @logger.info "oauth2 authentication start"
    url = @client.auth_code.authorize_url(
      :scope => 'https://www.googleapis.com/auth/tasks',
      :redirect_uri => redirect_uri,
      :access_type => 'offline',
      :approval_prompt => 'force')
    puts "please open this OAuth2 authentication URL: #{url}"

    uri = URI.parse(redirect_uri)
    server = WEBrick::HTTPServer.new(:BindAddress => uri.host, :Port => uri.port, :Logger => @logger)
    trap(:INT){server.shutdown}

    server.mount_proc(uri.path){ |req, res|
      request_params = Rack::Utils.parse_query(req.query_string)
      @logger.info "accept queries: #{request_params.inspect}"

      @code = request_params['code']
      @logger.info "authenticate code is #{@code.inspect}"

      res.body = <<EOT
<html>
  <body>
  <h1>authorization successful</h1>
  <p>#{@code}</p>
  </body>
</html>
EOT
      @logger.info "webrick shutting down"
      server.shutdown
      @logger.info "shutdown"

      @logger.info "try to get access token"
      @token = @client.auth_code.get_token(@code, :redirect_uri => redirect_uri)
      @logger.info "got access token: #{@token.token.inspect}"
    }
    @logger.info "starting webrick server: #{uri.to_s}"
    server.start

    puts "authentication success"

    @token
  end

  def refresh(path=GoogleTaskAPI.default_dat_path)
    @logger.info "current state is " + token_params.ai
    @logger.info "refresh option specified: #{@no_refresh.inspect}"
    if @no_refresh
      @logger.info "refresh ignored"
      return 
    end

    new_token = @token.refresh!

    params = { 
      :refresh_token => @token.refresh_token,
      :expires_at => new_token.expires_at,
      :expires_in => new_token.expires_in
    }
    @token = OAuth2::AccessToken.new(@client, new_token.token, params) 

    @logger.info "refreshed!"
    @logger.info "refreshed state is " + token_params.ai

    @logger.info "try to save to #{path}"
    save_to_file(path)
    @logger.info "saved"
  end

  def token_params
    {
      :expires_at => @token.expires_at,
      :expires_in => @token.expires_in,
      :refresh_token => @token.refresh_token,
      :token => @token.token
    }
  end

  def save_to_file(path)
    File.open(path, "w"){ |f|
      f.write token_params.to_yaml
    }
  end

  def load_from_file(path)
    opts = YAML.load_file(path)
    token = opts.delete(:token)
    @token = OAuth2::AccessToken.new(@client, token, opts) 
  end
end

class GoogleTask
  public
  def initialize(options={})
    @client_id = options[:client_id] or raise ArgumentError.new
    @client_secret = options[:client_secret] or raise ArgumentError.new
    @logger = options[:logger] ||= Logger.new(nil)
    @no_refresh = options[:no_refresh] ||= false

    @gs_api = GoogleTaskAPI.new(:client_id => @client_id, :client_secret => @client_secret, :logger => @logger, :no_refresh => @no_refresh)
  end

  def tasks(list_ident = '@default')
    @gs_api.task_list(list_ident)["items"]
  end

  def clear(list_ident = '@default')
    @gs_api.task_clear(list_ident)
  end

  def add(task_name, list_ident = '@default')
    @gs_api.task_insert(list_ident, :title => task_name)
  end

  def regexp_if(regexp, list_ident = '@default')
    matched = []
    @gs_api.task_list(list_ident)["items"].each{ |item|
      if regexp.match(item["title"])
        yield(item) if block_given?
        matched << item
      end
    }
    matched
  end

  def delete(task_number, list_ident = '@default')
    task_proc(task_number){ |task|
      @gs_api.task_delete(list_ident, task["id"])
    }
  end

  def delete_if(regexp, list_ident = '@default')
    regexp_if(regexp, list_ident){ |item|
      @logger.info "try to delete: #{item["title"]} (#{item["id"]})"
      @gs_api.task_delete(list_ident, item["id"])
      @logger.info "deleted: #{item["title"]}"
    }
  end

  def done(task_number, list_ident = '@default')
    task_proc(task_number) { |task|
      @gs_api.task_update(list_ident, task["id"], "status" => "completed")
    }
  end

  def done_if(regexp, list_ident = '@default')
    regexp_if(regexp, list_ident){ |item|
      @logger.info "try to done task: #{item["title"]} (#{item["id"]})"
      @gs_api.task_update(list_ident, item["id"], "status" => "completed")
      @logger.info "updated: #{item["title"]}"
    }
  end

  def lists(username = '@me')
    @gs_api.tasklist_list(username)["items"]
  end

  def all_tasks(username = '@me')
    hash = {}
    @gs_api.tasklist_list(username)["items"].map{ |item|
      hash[item["title"]] ||= []
      hash[item["title"]] += tasks(item["id"]).map{|e| e["title"]}
    }
    hash
  end

  def show(username = '@me')
    all_tasks.each{ |list_title, tasks|
      puts "*#{list_title}"
      tasks.each{ |task|
        puts "\t#{task}"
      }
    }
  end

  private
  def task_proc(task_number, &block)
    tasks.each_with_index{ |task, index|
      if index == task_number
        block.call(task)
        break
      end
    }
  end
end

class GoogleTaskCLI
  def initialize(options={})
    @gtasks = GoogleTask.new(options)
  end

  def list(scope = 'default')
    case scope
    when 'all'
      list_all
    when /^[0-9]+/
      list_number = scope.to_i
      list_id = @gtasks.lists[list_number]["id"]
      print_list(list_id)
    when 'default'
      print_list('@default')
    else
      raise ArgumentError
    end
  end

  def lists
    print_selector @gtasks.lists.map{|e| e["title"]}
  end

  def list_all
    @gtasks.show
  end

  def print_list(list_id)
    @gtasks.tasks(list_id).each_with_index{ |task, index|
      title = task["title"]
      if task["status"] == 'completed'
        done_string = '☑'
      else
        done_string = '☐'
      end
      puts "[#{index}] #{done_string} #{title}"
    }
  end

  def add(task_name)
    @gtasks.add(task_name)
    list
  end

  def clear
    @gtasks.clear
    list
  end

  def done(param)
    # 数字オンリーだったら番号指定のタスクdoneと認識する
    if param =~ /^[0-9]+$/
      @gtasks.done(param.to_i)
    else
      # それ以外は正規表現として認識、タスク名が正規表現にマッチしたものをすべて完了する
      @gtasks.done_if Regexp.new(param.to_s)
    end
    list
  end

  def delete(param)
    # 数字オンリーだったら番号指定のタスクdoneと認識する
    if param =~ /^[0-9]+$/
      @gtasks.delete(param.to_i)
    else
      # それ意外は正規表現として認識、タスク名がマッチしたものをすべて完了する
      @gtasks.delete_if Regexp.new(param.to_s)
    end
    list
  end

  def choice
    items = @gtasks.tasks.map{|e| e["title"]}
    rand_index = ((rand * items.size) + 1).to_i
    build_selector_format(rand_index, items[rand_index]).display
  end

  private
  # 指定された配列を番号表記の文字列に変換します
  def array_to_selector(array)
    string = ""
    array.each_with_index{ |item, index|
      string += build_selector_format(index, item)
    }
    string
  end

  def print_selector(array)
    array_to_selector(array).display
  end

  def build_selector_format(index, identify, linefeed=$/)
    "[#{index}] #{identify}#{linefeed}"
  end
end
