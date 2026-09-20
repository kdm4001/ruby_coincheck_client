# frozen_string_literal: true

lib = File.expand_path("lib", __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "ruby_coincheck_client/version"

Gem::Specification.new do |spec|
  spec.name = "ruby_coincheck_client"
  spec.version = RubyCoincheckClient::VERSION
  spec.authors = ["coincheck"]
  spec.email = ["info@coincheck.jp"]

  spec.summary = "A Ruby client for the Coincheck Exchange API"
  spec.homepage = "https://github.com/coincheckjp/ruby_coincheck_client"
  spec.required_ruby_version = ">= 3.1"
  spec.metadata = {
    "allowed_push_host" => "https://rubygems.org",
    "changelog_uri" => "#{spec.homepage}/blob/master/CHANGELOG.md",
    "source_code_uri" => spec.homepage,
    "rubygems_mfa_required" => "true"
  }

  spec.files = Dir["lib/**/*.rb", "README.md", "CHANGELOG.md"]
  spec.require_paths = ["lib"]

  spec.add_development_dependency "bundler", ">= 2.4", "< 5"
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "rspec", "~> 3.13"
  spec.add_development_dependency "webmock", "~> 3.24"
end
