require 'rake'
require 'rake/gempackagetask'


specification = Gem::Specification.new do |s|
  s.platform = Gem::Platform::RUBY
  s.name   = "fake_braintree"
  s.summary = "A Fake Implementation of the Braintree Credit Card Processing API"
  s.version = "0.0.2"
  s.author = "David Vollbracht"
  s.description = s.summary
  s.email = "david.vollbracht@gmail.com"
  s.homepage = ""
  s.has_rdoc = false
  s.files = FileList['{lib,test}/**/*.{rb,rake}', 'Rakefile'].to_a
end

Rake::GemPackageTask.new(specification) do |package|
  package.need_zip = true
  package.need_tar = true
end

