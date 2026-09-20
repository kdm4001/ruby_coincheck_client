# frozen_string_literal: true

require "spec_helper"

describe RubyCoincheckClient do
  it "has a version number" do
    expect(RubyCoincheckClient::VERSION).to match(/\A\d+\.\d+\.\d+\z/)
  end
end
