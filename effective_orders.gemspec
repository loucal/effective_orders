$:.push File.expand_path("../lib", __FILE__)

# Maintain your gem's version:
require "effective_orders/version"

# Describe your gem and declare its dependencies:
Gem::Specification.new do |s|
  s.name        = "effective_orders"
  s.version     = EffectiveOrders::VERSION
  s.authors     = ["Code and Effect"]
  s.email       = ["info@codeandeffect.com"]
  s.homepage    = "https://github.com/code-and-effect/effective_orders"
  s.summary     = "Effectively manage the Cart -> Order process in an application."
  s.description = "A full solution for managing orders with ActiveAdmin integration"

  s.files = Dir["{app,config,db,lib}/**/*"] + ["MIT-LICENSE", "Rakefile", "README.md"]
  s.test_files = Dir["spec/**/*"]

  s.add_dependency "rails"
  s.add_dependency "coffee-rails"
  s.add_dependency "formtastic"
  s.add_dependency "haml"
  s.add_dependency "migrant"

  s.add_development_dependency "factory_girl_rails"
  s.add_development_dependency "rspec-rails"
  s.add_development_dependency "shoulda-matchers"
  s.add_development_dependency "sqlite3"

  s.add_development_dependency "guard"
  s.add_development_dependency "guard-rspec"
  s.add_development_dependency "guard-livereload"
end