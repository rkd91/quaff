Gem::Specification.new do |s|
  s.name        = 'quaff'
  s.version     = '0.8.0'
  s.summary     = "Quaff"
  s.description = "A Ruby library for writing SIP test scenarios"
  s.authors     = ["Rob Day"]
  s.email       = 'rkd@rkd.me.uk'
  s.files       = Dir["lib/quaff.rb", "lib/quaff/*.rb"]
  s.add_runtime_dependency "milenage", '>= 0.1.0'
  s.add_runtime_dependency "abnf-parsing", '>= 0.2.0'
  s.homepage    =
    'http://github.com/rkday/quaff'
  s.license       = 'GPL3'
end
