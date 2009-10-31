require 'rubygems'
require 'spec'

SPEC_ROOT = File.dirname(__FILE__) 

require SPEC_ROOT + '/../lib/sirop.rb'
require 'fileutils'

describe Sirop do

  def sirop_setup
    Sirop.setup! @sirop_opts
  end
  
  before :all do
    @example_dir = File.join(SPEC_ROOT, '.sirop')
    @sirop_opts = { :path => @example_dir, :db => { :size_mb => 1 } }
  end

  describe '#setup!' do

    before do
      FileUtils.rm_rf(@example_dir)
    end

    it 'should setup the index, database and storage dir' do
      Sirop.index.should be_nil
      Sirop.db.should be_nil
      File.exist?(@example_dir).should be_false

      sirop_setup

      File.exist?(@example_dir).should be_true
      Sirop.index.should be_kind_of(Ferret::Index::Index)
      Sirop.db.should be_kind_of(LocalMemCache)
    end

  end

  describe do

    before(:all) do
      sirop_setup if Sirop.db.nil?  
      unless defined?(SiropSimple)

        class SiropSimple
          include Sirop
        end

        class SiropProps
          include Sirop
          property :name, :index => true
          property :size
        end

        class SiropAssoc
          include Sirop
          property :propeller, :model => SiropProps
        end

        class SiropNoAccessors
          include Sirop
          property :custom, :accessors => false
        end

        class SiropLazy
          include Sirop
          property :daisy, :lazy => true
        end

      end
    end

    after(:each) do
      Sirop.clear!
    end

    describe '#clear!' do

      it 'should clear the database and index' do
        Sirop.clear!
        Sirop.db.size.should == 0
        5.times { |i| Sirop.db.set("foo#{i}", "bar#{i}") }
        Sirop.db.size.should == 5

        Sirop.clear!
        Sirop.db.size.should == 0
      end

    end

      describe '#next_sequence' do

      it 'should generate UUIDs' do
        Sirop.setup! @sirop_opts.merge(:uuid => true)
        5.times do
          Sirop.next_sequence("foobar").should =~ 
            /\w{8}-\w{4}-\w{4}-\w{4}-\w{12}/
        end
      end

      it 'should generate increasing numbers per domain' do
        Sirop.setup! @sirop_opts.merge(:uuid => false)
        Sirop.clear!
        Sirop.next_sequence("foobar").should == 1
        Sirop.next_sequence("foobar").should == 2
        Sirop.next_sequence("barfoo").should == 1
      end

    end

    describe '#db_set and #db_get' do

      it 'should marshall and unmarshall objects' do
        obj = {:foo => ["bar"], 123 => "baz"}

        Sirop.db_set("obj", obj)
        Sirop.db_get("obj").should == obj
      end

      it 'should work with nil values' do
        Sirop.db_set("nothing", nil)
        Sirop.db_get("nothing").should be_nil
      end

    end

    describe Sirop::InstanceMethods do

      before :each do
        Sirop.setup! @sirop_opts.update(:uuid => false) if Sirop.config[:uuid]
      end

      describe '#id' do

        it 'should return new ids for new records' do
          o = SiropSimple.new
          id = o.id
          id.should be_kind_of(Fixnum)
          o.id.should == id
        end

      end

      it '#doc_key should return a string with the domain and id' do
        SiropSimple.new.doc_key.should =~ /SiropSimple\/\d+/
      end

      describe '#==' do

        it 'should recognize objects with the same doc_key as equal' do
          o = SiropSimple.new
          fake = Struct.new(:doc_key).new("SiropSimple/#{o.id}")
          o.should == fake 
          o.should == o
        end

        it 'should not recognize objects with different doc_keys as equal' do
          o1 = SiropSimple.new
          o2 = SiropSimple.new
          o1.should_not == o2
        end

      end

      describe '#save' do

        it 'should add new objects to the db and index' do
          o = SiropProps.new
          o.name = "Hello"
          o.save
          Sirop.db.size.should >= 1
          Sirop.index.size.should == 1
        end

        it 'should save changed objects to the db and index' do
          o = SiropProps.new
          o.name = "hello"
          o.save

          Sirop.index.should_receive(:<<).once
          Sirop.should_receive(:db_set).once
          o.name = "goodbye"
          o.save
        end

        it 'should not re-add objects to the index when no indexed fields have changed' do
          o = SiropProps.new
          o.name = "hello"
          o.save

          Sirop.index.should_not_receive(:<<)
          Sirop.should_receive(:db_set).once
          o.size = 4
          o.save
        end

      end

      it '#destroy should destroy a record' do
        o = SiropSimple.new
        o.save

        Sirop.index.should_receive :delete
        Sirop.db.should_receive :delete

        o.destroy
      end

    end

    describe Sirop::ClassMethods do

      it '#all should return all records of a class' do
        Sirop.clear!
        3.times { SiropSimple.new.save }
        all = SiropSimple.all
        all.size.should == 3
        all.each {|o| o.should be_kind_of(SiropSimple)}
      end

      it '#each should iterate through all records of a class' do
        3.times { SiropSimple.new.save }
        prev = nil
        SiropSimple.each do |o|
          o.should be_kind_of(SiropSimple)
          o.should_not == prev
          prev = o
        end
      end

      it '#search should perform a ferret query scoped by the class and iterate through the results' do
        3.times {|i| o = SiropProps.new; o.name = "Foo #{i}"; o.save }
        3.times {|i| o = SiropProps.new; o.name = "Bar #{i}"; o.save }

        SiropProps.search("name: Foo") do |o, score|
          o.name.should =~ /^Foo/
          score.should be_kind_of(Float)
        end
      end

      describe '#find' do

        before(:each) do
          10.times { SiropSimple.new.save }
        end

        it 'should find a single record if given an id' do
          SiropSimple.find(4).should be_kind_of(SiropSimple)
        end

        it 'should find multiple records if given an array' do
          found = SiropSimple.find([1,2,3])
          found.size.should == 3
          found.each {|o| o.should be_kind_of(SiropSimple)}
        end

        it 'should raise Sirop::RecordNotFound if the records cannot be found' do
          lambda {
            SiropSimple.find(999)
          }.should raise_error(Sirop::RecordNotFound)
        end

        it 'should raise Sirop::RecordNotFound if not all records specified in the array could be found' do
          lambda {
            SiropSimple.find([1, 2, 3, 999])
          }.should raise_error(Sirop::RecordNotFound)
        end

      end

      describe '#get' do

        it 'should materialize a record when given the doc_key' do
          o = SiropSimple.new
          o.save
          SiropSimple.get("SiropSimple/1").should == o
        end

        it 'should return nil for unknown records' do
          SiropSimple.get("SiropSimple/999").should be_nil
        end

      end

      it '#delete should remove a record with the given id' do
        SiropSimple.should_receive(:remove).once.with("SiropSimple/1")
        SiropSimple.delete 1
      end

      it '#remove should remove a record given the doc_key' do
        o = SiropSimple.new; o.save
        SiropSimple.get(o.doc_key).should_not be_nil
        SiropSimple.remove(o.doc_key)
        SiropSimple.get(o.doc_key).should be_nil
      end

      it '#properties should return a hash with property meta data' do
        SiropProps.properties.should have_key(:size)
      end

      describe '#property' do

        it 'should skip defining accessors if told to' do
          o = SiropNoAccessors.new
          SiropNoAccessors.properties.should have_key(:custom)
          o.should_not respond_to(:custom)
          o.should_not respond_to(:custom=)
        end

        it 'should define lazy attributes if told to' do
          o = SiropLazy.new; o.daisy = 'lazy'; o.save
          o2 = SiropLazy.find(1)
          o2.instance_variable_get('@daisy').should be_nil
          o2.daisy
          o2.instance_variable_get('@daisy').should == 'lazy'
        end

        it 'should define associations if given a model' do
          o = SiropAssoc.new
          a = SiropProps.new; a.name = 'foo'; a.save
          o.propeller = [a]
          o.save
          SiropAssoc.find(1).propeller.should == [a]
        end

        it 'should define an indexed attribute if told to' do
          o = SiropProps.new
          o.size = "large"; o.name = "bart"; o.save
          found_by_size, found_by_name = 0, 0
          SiropProps.search("size: large") {|*args| found_by_size += 1}
          SiropProps.search("name: bart") {|*args| found_by_name += 1}

          found_by_name.should == 1
          found_by_size.should == 0
        end

      end

      describe do

        it '#domain= should allow overriding the default domain' do
          SiropSimple.domain = "FooBar"
          o = SiropSimple.new
          o.doc_key.should == 'FooBar/1'

          SiropSimple.domain = SiropSimple.to_s
        end

        it '#fold_association should convert records into ids' do
          objects = (0..3).map { o = SiropSimple.new; o.save; o }
          SiropSimple.fold_association(objects).should == [1,2,3,4]
        end

        it '#unfold_association should convert ids to records' do
          objects = [
            (o = SiropProps.new; o.save; o),
            (o = SiropProps.new; o.save; o)
          ]
          SiropAssoc.unfold_association(:propeller, [1,2]).should == objects
        end

      end

    end
  end
end
