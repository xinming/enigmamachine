# Gems
#
require 'rubygems'
require 'sinatra/base'
require 'data_mapper'
require 'ruby-debug'
require 'eventmachine'
require 'rack-flash'
require 'dm-validations'
require 'dm-migrations'
require 'state_machine'
require 'logger'
require 'streamio-ffmpeg'
require 'em-http-request'

# Extensions to Sinatra
#
require File.dirname(__FILE__) +  '/ext/partials'
require File.dirname(__FILE__) +  '/ext/array_ext'
require File.dirname(__FILE__) +  '/ext/attribute_accessors'
# Enigma code
#
require File.dirname(__FILE__) + '/enigmamachine'
require File.dirname(__FILE__) + '/enigmamachine/models/encoder'
require File.dirname(__FILE__) + '/enigmamachine/models/encoding_task'
require File.dirname(__FILE__) + '/enigmamachine/models/video'
require File.dirname(__FILE__) + '/enigmamachine/encoding_queue'
require File.dirname(__FILE__) + '/enigmamachine/download_queue'



class EnigmaMachine < Sinatra::Base

  # Database config
  #
  configure :production do
    db = "sqlite3:///#{Dir.pwd}/enigmamachine.sqlite3"
    DataMapper.setup(:default, db)
  end

  configure :development do
    db = "sqlite3:///#{Dir.pwd}/enigmamachine.sqlite3"
    DataMapper.setup(:default, db)
  end

  configure :test do
    db = "sqlite3::memory:"
    DataMapper.setup(:default, db)
    @@username = 'admin'
    @@password = 'admin'
  end

  configure :production, :test, :development do
    Video.auto_migrate! unless Video.storage_exists?
    Encoder.auto_migrate! unless Encoder.storage_exists?
    EncodingTask.auto_migrate! unless EncodingTask.storage_exists?
  end

  configure :production, :development do
    DataMapper.auto_upgrade!
    unless File.exist? File.join(Dir.getwd, 'config.yml')
      FileUtils.cp(File.dirname(__FILE__) +  '/generators/config.yml', Dir.getwd)
    end
    config = YAML.load(File.read(Dir.getwd + "/config.yml"))
    @@username = config['username']
    @@password = config['password']
    @@threads = config['threads']
    @@enable_http_downloads = config['enable_http_downloads']
    @@download_storage_path = config['download_storage_path']
  end

  # Set the views to the proper path inside the gem
  #
  set :views, File.dirname(__FILE__) + '/enigmamachine/views'
  set :public, File.dirname(__FILE__) + '/enigmamachine/public'

  # Let's bind this thing to localhost only, it'd be suicidal to put it on the
  # internet by binding it to all available interfaces.
  #
  set :bind, 'localhost'

  # Register helpers
  #
  helpers do
    include Sinatra::Partials
    alias_method :h, :escape_html
  end


  # Include flash notices
  #
  use Rack::Session::Cookie
  use Rack::Flash
  use Rack::MethodOverride

  # Starts the enigma encoding thread. The thread will be reabsorbed into the
  # main Sinatra/thin thread once the periodic timer is added.
  #
  configure do
    Thread.new do
      until EM.reactor_running?
        sleep 1
      end
      Video.reset_encoding_videos
      Video.reset_downloading_videos
      encode_queue = EncodingQueue.new
      download_queue = DownloadQueue.new
    end
  end

  # Set up Rack authentication
  #
  # Provides minimal security for shared hosts.
  #
  use Rack::Auth::Basic do |username, password|
    [username, password] == [@@username, @@password]
  end

  # Some accessors for config variables
  #
  cattr_accessor :download_storage_path, :enable_http_downloads, :threads


  # Shows the enigma status page.
  #
  get '/' do
    @videos = Video.all(:limit => 50, :order => [:created_at.desc])
    erb :index
  end

  # Displays a list of all available encoders.
  #
  get '/encoders' do
    @encoders = Encoder.all
    erb :'encoders/index'
  end


  # Displays a form to create a new encoder.
  #
  get '/encoders/new' do
    @encoder = Encoder.new
    erb :'encoders/new'
  end


  # Displays an encoder.
  #
  get '/encoders/:id' do |id|
    @encoder = Encoder.get(id)
    @encoding_task = EncodingTask.new
    erb :'encoders/show'
  end


  # Displays an edit page for an encoder.
  #
  get '/encoders/:id/edit' do |id|
    @encoder = Encoder.get(id)
    erb :"encoders/edit"
  end


  # Creates an encoder.
  #
  post '/encoders' do
    @encoder = Encoder.new(params[:encoder])
    if @encoder.save
      flash[:notice] = "Encoder created."
      redirect "/encoders/#{@encoder.id}"
    else
      erb :'encoders/new'
    end
  end


  # Updates an encoder
  #
  put '/encoders/:id' do |id|
    @encoder = Encoder.get(id)
    if @encoder.update(params[:encoder])
      flash[:notice] = "Encoder updated."
      redirect '/encoders'
    else
      erb :"encoders/edit"
    end
  end

  # Deletes an encoder
  #
  delete '/encoders/:id' do |id|
    @encoder = Encoder.get(id)
    @encoder.destroy!
    redirect '/encoders'
  end


  # Show a form to make a new encoding task
  #
  get '/encoding_tasks/new/:encoder_id' do |encoder_id|
    @encoding_task = EncodingTask.new
    @encoding_task.encoder = Encoder.get(encoder_id)
    erb :'encoding_tasks/new'
  end


  # Creates an encoding task.
  #
  post '/encoding_tasks/:encoder_id' do |encoder_id|
    @encoding_task = EncodingTask.new(params[:encoding_task])
    @encoder = Encoder.get(encoder_id)
    @encoding_task.encoder = @encoder
    if @encoding_task.save
      flash[:notice] = "Encoding task created."
      redirect "/encoders/#{@encoding_task.encoder.id}"
    else
      erb :'encoding_tasks/new'
    end
  end


  # Gets the edit form for an encoding task
  #
  get '/encoding_tasks/:id/edit' do |id|
    @encoding_task = EncodingTask.get(id)
    erb :'encoding_tasks/edit'
  end


  # Updates an encoding task.
  #
  put '/encoding_tasks/:id' do |id|
    @encoding_task = EncodingTask.get(id)
    if @encoding_task.update(params[:encoding_task])
      redirect "/encoders/#{@encoding_task.encoder.id}"
    else
      erb :'encoding_tasks/edit'
    end
  end

  # Deletes an encoding task.
  #
  delete '/encoding_tasks/:id' do |id|
    @encoding_task = EncodingTask.get(id)
    @encoder = @encoding_task.encoder
    @encoding_task.destroy!
    redirect "/encoders/#{id}"
  end

  # Displays a list of available videos.
  #
  get '/videos' do
    @completed_videos = Video.complete
    @encoding_videos = Video.encoding
    @videos_with_errors = Video.with_encode_errors
    @unencoded_videos = Video.unencoded
    @downloading_videos = Video.downloading
    @waiting_for_download_videos = Video.waiting_for_download
    erb :'videos/index'
  end


  # Displays a form for creating a new video
  #
  get '/videos/new' do
    @video = Video.new
    @encoders = Encoder.all
    erb :'videos/new'
  end


  # Creates a new video
  #
  post '/videos' do
    @video = Video.new(params[:video])
    @encoder = Encoder.get(params[:encoder_id])
    @video.encoder = @encoder
    if @video.save
      redirect '/videos'
    else
      @encoders = Encoder.all
      erb :'videos/new'
    end
  end

  # Deletes a video.
  #
  delete '/videos/:id' do |id|
    @video = Video.get(id)
    @video.destroy
    redirect "/videos"
  end

end

