require 'sinatra/base'
require 'erubis'
require 'json'
require 'active_support'

require 'mongodb_logger/server/view_helpers'
require 'mongodb_logger/server/partials'
require 'mongodb_logger/server/content_for'
require 'mongodb_logger/server/sprokets'

require 'mongodb_logger/server/model/additional_filter'
require 'mongodb_logger/server/model/filter'
require 'mongodb_logger/server/model/analytic'

require 'mongodb_logger/server_config'

if defined? Encoding
  Encoding.default_external = Encoding::UTF_8
end

module MongodbLogger
  class Server < Sinatra::Base
    helpers Sinatra::ViewHelpers
    helpers Sinatra::Partials
    helpers Sinatra::ContentFor
    
    dir = File.dirname(File.expand_path(__FILE__))

    set :views,         "#{dir}/server/views"
    #set :environment, :production
    set :static, true

    helpers do
      include Rack::Utils
      alias_method :h, :escape_html
      # pipeline
      include AssetHelpers
      
      def current_page
        url_path request.path_info.sub('/','')
      end
      
      def class_if_current(path = '')
        'class="active"' if current_page[0, path.size] == path
      end

      def url_path(*path_parts)
        [ path_prefix, path_parts ].join("/").squeeze('/')
      end
      alias_method :u, :url_path

      def path_prefix
        request.env['SCRIPT_NAME']
      end
      
    end
    
    before do
      begin
        if ServerConfig.db && ServerConfig.collection
          @db = ServerConfig.db
          @collection = ServerConfig.collection
        else
          @db = Rails.logger.mongo_connection
          @collection = @db[Rails.logger.mongo_collection_name]
        end
        @collection_stats = @collection.stats
      rescue => e
        erb :error, {:layout => false}, :error => "Can't connect to MongoDB!"
        return false
      end
      
      cache_control :private, :must_revalidate, :max_age => 0
    end

    def show(page, layout = true)
      begin
        erb page.to_sym, {:layout => layout}
      rescue => e
        erb :error, {:layout => false}, :error => "Error in view. Debug: #{e.inspect}"
      end
    end


    get "/?" do
      redirect url_path(:overview)
    end

    %w( overview ).each do |page|
      get "/#{page}/?" do
        @filter = ServerModel::Filter.new(params[:filter])
        @logs = @collection.find(@filter.get_mongo_conditions).sort('$natural', -1).limit(@filter.get_mongo_limit)
        show page, !request.xhr?
      end
    end
    
    get "/tail_logs/?:log_last_id?" do
      buffer = []
      last_id = nil
      if params[:log_last_id] && !params[:log_last_id].blank?
        log_last_id = params[:log_last_id]
        tail = Mongo::Cursor.new(@collection, :tailable => true, :order => [['$natural', 1]], 
          :selector => {'_id' => { '$gt' => BSON::ObjectId(log_last_id) }})
        while log = tail.next
          buffer << partial(:"shared/log", :object => log)
          log_last_id = log["_id"].to_s
        end
        buffer.reverse!
      else
        @log = @collection.find_one({}, {:sort => ['$natural', -1]})
        log_last_id = @log["_id"].to_s unless @log.blank?
      end
      
      content_type :json
      { :log_last_id => log_last_id, 
        :time => Time.now.strftime("%F %T"), 
        :content => buffer.join("\n"), 
        :collection_stats => partial(:"shared/collection_stats", :object => @collection_stats) }.to_json
    end
    
    get "/changed_filter/:type" do
      type_id = ServerModel::AdditionalFilter.get_type_index params[:type]
      conditions = ServerModel::AdditionalFilter::VAR_TYPE_CONDITIONS[type_id]
      values = ServerModel::AdditionalFilter::VAR_TYPE_VALUES[type_id]
      
      content_type :json
      { 
        :type_id => type_id,
        :conditions => conditions,
        :values => values
      }.to_json
    end
    
    # log info
    get "/log/:id" do
      @log = @collection.find_one(BSON::ObjectId(params[:id]))
      show :show_log, !request.xhr?
    end
    
    # log info right
    get "/log_info/:id" do
      @log = @collection.find_one(BSON::ObjectId(params[:id]))
      partial(:"shared/log_info", :object => @log)
    end
    
    get "/add_filter/?" do
      @filter = ServerModel::Filter.new(nil)
      @filter_more = ServerModel::AdditionalFilter.new(nil, @filter)
      partial(:"shared/dynamic_filter", :object => @filter_more)
    end
    
    # analytics
    %w( analytics ).each do |page|
      get "/#{page}/?" do
        @analytic = ServerModel::Analytic.new(@collection, params[:analytic])
        show page, !request.xhr?
      end
      post "/#{page}/?" do
        @analytic = ServerModel::Analytic.new(@collection, params[:analytic])
        @analytic_data = @analytic.get_data
        content_type :json
        @analytic_data.to_json
      end
    end
    
    error do
      erb :error, {:layout => false}, :error => 'Sorry there was a nasty error. Maybe no connection to MongoDB. Debug: ' + env['sinatra.error'].inspect + '<br />' + env.inspect
    end
    
  end
end
