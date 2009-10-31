require 'localmemcache'
require 'ferret'
require 'pathname'

module Sirop

  # the localmemcache db
  @@db = nil
  def self.db; @@db end
  
  # the ferret index
  @@index = nil
  def self.index; @@index end
  
  # general config hash
  @@config = {}
  def self.config; @@config end
  
  def self.included(base)
    raise "Please call Sirop.setup! before defining any models" unless @@index
    base.send :include, InstanceMethods
    base.send :extend, ClassMethods
    config[base] ||= { :properties => {}, :domain => base.to_s }
  end
  
  # == Options:
  # +:uuid+:: if true, uses UUIDs as record ids. Recommened if more than one app generates records
  # +:path+:: where to persist the db and index. Defaults to ./db in the scripts directory 
  # +:index+:: options hash passed to ferret (optional)
  # +:db+:: options hash passed to localmemcache (optional)
  def self.setup!(opts = {})

    config[:path] = init_storage_dir(opts[:path])
  
    if config[:uuid] = opts[:uuid]
      require 'uuid'
      @@uuid = UUID.new
    else
      @@mx = Mutex.new
    end
    
    init_index(opts[:index] || {})
    init_db(opts[:db] || {})
  end
  
  # Clears the complete datastore and index
  def self.clear!
    db.clear
    index.query_delete('*')
  end
  
  # Generates a new sequence number for the given +domain+.
  #
  # +domain+:: required unless UUIDs is used
  def self.next_sequence(domain = nil)
    if config[:uuid]
      @@uuid.generate
    else
      key = "_seq_#{domain}"
      @@mx.synchronize do
        id = db.get(key).to_i + 1
        db.set(key, id.to_s)
        id
      end 
    end
  end

  # sets the marshaled +value+ for the +key+
  def self.db_set(key, value)
    db.set(key, Marshal.dump(value))
  end

  # loads and unmarshals the value for +key+
  def self.db_get(key)
    if value = db.get(key)
      Marshal.load(value) 
    end
  end
    
  protected

  def self.init_storage_dir(path = nil)
    # Localmemcache often fails with absolute paths (permissions)
    # so we need to (reliably) compute the relative path here.
    path = Pathname.new(File.expand_path(path || File.join(
        File.dirname($0), '.sirop'))).relative_path_from(
        Pathname.new(Dir.pwd)).to_s

    unless File.directory?(path)
      require 'fileutils'
      FileUtils.mkdir_p(path)
    end
    
    path
  end
  
  def self.init_index(ferret_opts)
    @@index ||= Ferret::Index::Index.new(ferret_opts.
        merge(:path => File.join(config[:path], 'index'),
              :key => :_doc_key, :id_field => :_doc_key))

    unless index.field_infos.fields.include?(:_doc_key)
      index.field_infos.add_field(:_doc_key, :index => :untokenized_omit_norms, :store => :yes, :term_vector => :no)
    end
    
    unless index.field_infos.fields.include?(:id)
      index.field_infos.add_field(:id, :index => :untokenized_omit_norms, :store => :no, :term_vector => :no)
    end
  end

  def self.init_db(db_opts)
    @@db ||= LocalMemCache.new(db_opts.
        merge(:filename => File.join(config[:path], 'db.lmc')))
  end
  
  module InstanceMethods
  
    # The +id+ of the record. Either a Fixnum or a UUID string, depending on the :uuid-Option
    # for Sirop#setup!.
    def id
      @id ||= Sirop.next_sequence(self.class.domain)
    end
  
    # Returns the +doc_key+ for this record. The +doc_key+ is used by LocalMemCache and Ferret
    # to identify the record
    def doc_key
      @doc_key ||= "#{self.class.domain}/#{id}"
    end
  
    # Saves the record to LocalMemCache and Ferret.
    # only writes to ferret when indexed attributes have changed
    def save
      db_doc, idx_doc = { :id => id }, { :id => id, :_doc_key => doc_key, :_domain => self.class.domain }
      self.class.properties.each do |name, opts|
        value = opts[:lazy] ? send(name) : instance_variable_get("@#{name}")
        value = self.class.fold_association(value) if opts[:model]
        if opts[:lazy]
          Sirop.db_set("#{doc_key}/#{name}", value)
        else
          db_doc[name] = value
        end
        idx_doc[name] = value if opts[:index]
      end
      Sirop.db_set(doc_key, db_doc)
      Sirop.index << idx_doc unless idx_doc == @_prev_idx_doc
      @_prev_idx_doc = idx_doc
      true
    end
    
    def destroy
      self.class.remove(doc_key)
    end
   
    def ==(obj)
      obj.respond_to?(:doc_key) && obj.doc_key == doc_key
    end

  end

  class RecordNotFound < StandardError; end

  module ClassMethods
  
    # returns all records
    # === Options:
    # +:limit+: a number or +:all* which is the default
    def all(options = {})
      options[:limit] ||= :all
      # #scan is buggy in current master, se we use the slower search for now...
      # Sirop.index.scan("_domain:#{domain}", options).map { |nr| get(resolve(nr)) }
      Sirop.index.search("_domain:#{domain}", options).hits.map { |hit| get(resolve(hit.doc)) }
    end
  
    # Iterates through all records
    def each
      Sirop.index.search_each("_domain:#{domain}") do |nr, score|
        yield get(resolve(nr))
      end
    end
    
    # Searches for records using the given ferret +query+. Yields the record
    # and the ferret score
    # 
    # Example:
    #   Game.search("title:"Monkey Island") do |game, score|
    #     puts game.title
    #   end
    def search(query)
      Sirop.index.search_each("_domain:#{domain} AND (#{query})") do |nr, score|
        yield get(resolve(nr)), score
      end
    end

    # Find the record with the given +id+ or multiple ids.
    # raises RecordNotFound
    def find(id)
      if id.respond_to?(:collect)
        records = id.collect {|record_id| get("#{domain}/#{record_id}") }.compact
        raise RecordNotFound, "#{id.size} records expected, found only #{records.size}" if records.size < id.size
        records
      else
        get("#{domain}/#{id}") || raise(RecordNotFound, "the record with id #{id} was not found")
      end
    end

    # Materializes the document with the given +doc_key+.
    # The +doc_key+ is how LocalMemCache and Ferret identify records.
    def get(doc_key)
      if data = Sirop.db_get(doc_key)
        prev_idx_doc = { :_doc_key => doc_key, :_domain => domain }
        obj = allocate
        data.each do |name, value|
          name = name.to_sym
          if name == :id
            prev_idx_doc[:id] = value
          else
            prev_idx_doc[name] = value if properties[name][:index]
            value = unfold_association(name, value) if properties[name].has_key?(:model)
          end 
          obj.instance_variable_set("@#{name}", value)
        end
        # replacing a document in ferret is expensive, so we keep a copy
        # of all indexed fields to check them for changes on #save
        obj.instance_variable_set('@_prev_idx_doc', prev_idx_doc)
        return obj
      end
      nil
    end
    
    # Deletes the record with the given +id+
    def delete(id)
      remove("#{domain}/#{id}")
    end
    
    # Removes the document with the given +doc_key+ from the db and index.
    def remove(doc_key)
      Sirop.index.delete(doc_key)
      Sirop.db.delete(doc_key)
    end
  
    # == Options:
    # +:index:: if true or a hash of options for FieldInfos#add_field, this field gets indexed. You can't, 
    #           however, change existing FieldInfos this way. To do that, manipulate the Ferret index directly (<code>Sirop.index</code>)
    # +:accessors+:: if false no accessors will be generated, you have to make sure to define them
    #                manually. They must work on an instance variable with the name of the property
    # +:lazy+:: if true, this property is loaded lazily. Useful for binary data or long text.
    #           +:accessors+ is ignored in this case.
    # +:class+:: marks the property as object association which can hold a single object or a collection
    def property(name, opts = {})
      Sirop.config[self][:properties][name] = opts
      
      if index_opts = opts[:index]
        index_opts = {} unless index_opts.kind_of?(Hash)
        unless Sirop.index.field_infos.fields.include?(name)
          Sirop.index.field_infos.add_field(name, {:store => :no}.merge(index_opts))
        end
      end
      
      if opts[:lazy]
        define_lazy_attribute(name, opts.has_key?(:model))
      else
        attr_accessor name unless opts[:accessors] === false
      end
    end

    def properties
      Sirop.config[self][:properties]
    end
    
    def domain
      Sirop.config[self][:domain]
    end

    # Sets the domain of the class. Useful when renaming models
    def domain=(new_domain)
      Sirop.config[self][:domain] = new_domain
    end
    
    # +records+:: a single record or a collection of records
    def fold_association(records)
      if records
        if records.respond_to?(:collect)
          records.collect {|r| r.id}
        else
          records.id
        end
      end # else returns nil
    end

    # +name+:: the properties name
    # +ids+:: a single record id or a collection of record ids
    def unfold_association(name, ids)
      model = properties[name][:model]
      raise ArgumentError, "property #{name} does not define a model" unless model
      model.find(ids) if ids
    end

    protected
    
    def define_lazy_attribute(name, with_model = false)
      if with_model
        class_eval %Q{
          def #{name}                                             # def player
            @#{name} ||= self.class.unfold_association(:#{name},  #   @player ||= self.class.unfold_association(:player,
                Sirop.db_get("\#{doc_key}/#{name}"))              #       Lmfp.db_get("Game/3/player"))
          end                                                     # end
        }, __FILE__, __LINE__
      else
        class_eval %Q{
          def #{name}                                             # def text
            @#{name} ||= Sirop.db_get("\#{doc_key}/#{name}")      #   @text ||= Lmfp.db_get("Game/3/text")
          end                                                     # end
        }, __FILE__, __LINE__
      end
      attr_writer name
    end

    # resolves a ferret document number to the doc_key
    def resolve(nr)
      if doc = Sirop.index[nr]
        doc[:_doc_key]
      end
    end
  
  end

end
