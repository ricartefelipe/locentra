# frozen_string_literal: true

require "json"
require "rack/mock"
require_relative "concurrency_helper"
require "locentra/interfaces/http/app"
require_relative "../support/barrier"

# Duas requisições simultâneas de conversão do mesmo orçamento pela API v1. Com a mesma Idempotency-Key, uma
# converte e a outra devolve o resultado gravado (aguardando a primeira no índice da chave, quando chega
# durante a operação). Com chaves diferentes, a conversão é serializada pelo lock do orçamento: uma responde
# 201 e a outra 200, com a mesma reserva.
class ApiQuoteConversionRaceTest < DatabaseTest
  def setup
    super
    @org = create_organization
    @actor = @org[:actor]
    customer = create_customer(@actor)
    camera = create_product(@actor, sku: "CAM-RACE", tracking: "serialized")
    register_assets(@actor, camera, @org[:branch], 1)
    quote = uc(:create_quote).call(@actor, { customer_id: customer.id, branch_id: @org[:branch].id, lines: [line(camera, 1)],
                                             period: period("2026-03-10T08:00:00Z", "2026-03-12T08:00:00Z"), valid_until: t("2026-03-05T12:00:00Z") })
    uc(:send_quote).call(@actor, quote.id)
    @quote = uc(:approve_quote).call(@actor, quote.id, version: 1, approver_name: "Maria Compradora")
    @token = uc(:create_credential).call(@actor, name: "ERP", scopes: %w[quotes.write quotes.read reservations.write], expires_in_days: 30)["token"]
    @app = Locentra::Interfaces::HTTP::App.build(@system)
  end

  def convert(key)
    env = Rack::MockRequest.env_for("/api/v1/quotes/#{@quote.id}/convert", method: "POST", input: "{}",
                                                                           "CONTENT_TYPE" => "application/json",
                                                                           "HTTP_AUTHORIZATION" => "Bearer #{@token}", "HTTP_IDEMPOTENCY_KEY" => key)
    status, headers, body = @app.call(env)
    text = +""
    body.each { |part| text << part }
    body.close if body.respond_to?(:close)
    { status: status, replayed: headers["idempotent-replayed"] == "true", body: JSON.parse(text) }
  end

  def concurrently(keys)
    barrier = Barrier.new(keys.size)
    threads = keys.map do |key|
      Thread.new do
        barrier.wait
        convert(key)
      end
    end
    threads.map(&:value)
  end

  def reservations = owner_query("SELECT count(*) AS n FROM reservations").first["n"].to_i

  def test_same_key_converts_once_and_replays_the_stored_result
    results = concurrently(%w[conversao-mesma-chave conversao-mesma-chave])

    assert_equal [201, 201], results.map { |result| result[:status] }, results.inspect
    assert_equal([false, true], results.map { |result| result[:replayed] }.sort_by { |flag| flag ? 1 : 0 })
    assert_equal 1, results.map { |result| result[:body] }.uniq.size, "o replay devolve exatamente a mesma resposta"
    assert_equal 1, reservations
  end

  def test_different_keys_answer_created_and_existing_with_the_same_reservation
    results = concurrently(%w[conversao-chave-a conversao-chave-b]).sort_by { |result| result[:status] }

    assert_equal [200, 201], results.map { |result| result[:status] }, results.inspect
    assert_equal([false, false], results.map { |result| result[:replayed] })
    assert_equal 1, results.map { |result| result[:body]["reservation"]["id"] }.uniq.size
    assert_equal [1, "converted"], [reservations, uc(:get_quote).call(@actor, @quote.id)[:quote].status]
  end
end
