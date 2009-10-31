require 'rubygems'
require File.dirname(__FILE__) + '/../lib/sirop.rb'


Sirop.setup! :db => {:mb_size => 1}
Sirop.clear!

class Player
  include Sirop
  property :name
end

p1 = Player.new
p1.name = "Guybrush"
p1.save

p2 = Player.new
p2.name = "Threepwood"
p2.save

class LongDescription
  include Sirop
  property :pretty_long_text
end

class Game
  include Sirop

  # some normal attributes
  property :title, :index => true
  property :name
  # with custom accessors
  property :owner, :accessors => false

  # and lazy loading
  property :description, :index => true, :lazy => true

  # and associations
  property :players, :index => true, :model => Player
  property :long_description, :model => LongDescription, :lazy => true

  
  def owner=(new_owner)
    @owner = new_owner
  end
  
  def owner
    @owner || raise("no owner set!")
  end

end

puts "Games:"

g1 = Game.new
g1.title = "Monkey Island"
g1.players = [p1]
g1.save

puts "#{g1.id}: #{g1.title}"

g2 = Game.new
g2.title = "Leisure Suit Larry"
g2.description = "Tolle Beschreibung"
g2.players = [p1, p2]
g2.save

puts "#{g2.id}: #{g2.title}"

p3 = Game.new
p3.title = "Day of the Tentacle"
p3.players = []
long_desc = LongDescription.new
long_desc.pretty_long_text = "Lorem ipsum dolor sit amet, consetetur sadipscing elitr, sed diam nonumy eirmod tempor invidunt ut."
long_desc.save
p3.long_description = long_desc
p3.save

puts "#{p3.id}: #{p3.title}"

puts
puts "Listing all games:"
puts
Game.each do |game|
  puts "Title: #{game.title}"
  puts "Description: #{game.description}"
  if game.long_description
    puts "Long description: #{game.long_description.pretty_long_text}"
  end
  puts "Players: #{game.players.map {|p| p.name}.inspect}"
end

puts
puts "Seaching for games with 'Larry'"
puts
Game.search("Larry") do |game, score|
  puts "Title: #{game.title}"
end
puts

puts
puts "Searching for games with player: #{p2.id} (#{p2.name})"
puts
Game.search("players: #{p2.id}") do |game, score|
  puts "Title: #{game.title}"
  puts "Players: #{game.players.map {|p| p.name}.inspect}"
end
puts

g1.name = "Foo"
g1.save

