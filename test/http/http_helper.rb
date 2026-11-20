# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/database"
require "rack/test"
require "rack/lint"
require "locentra/interfaces/http/app"

class HttpTest < DatabaseTest
  include Rack::Test::Methods

  def app
    @app ||= Rack::Lint.new(Locentra::Interfaces::HTTP::App.build(@system))
  end

  def login(email, password = "senha-muito-segura-1")
    post "/entrar", { "email" => email, "senha" => password }

    assert_equal 303, last_response.status, last_response.body[0, 500]
    follow_redirect! while last_response.redirect?
  end

  # Token CSRF extraído da página renderizada (o mesmo que um navegador usaria).
  def csrf
    get "/" unless last_response&.body.to_s.include?("_csrf")
    last_response.body[/name="_csrf" value="([^"]+)"/, 1] || raise("token CSRF não encontrado")
  end

  def post_form(path, params)
    token = csrf
    post path, params.merge("_csrf" => token)
  end

  def json_body = JSON.parse(last_response.body)
end
