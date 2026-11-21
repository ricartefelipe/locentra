# frozen_string_literal: true

require "json"
require "rack/mock"
require_relative "concurrency_helper"
require "locentra/interfaces/http/app"
require_relative "../support/barrier"
require_relative "../support/operations_support"

# Duas entregas simultâneas da mesma retirada pela API v1, com chaves diferentes: o lock da reserva e da
# retirada serializa as duas, e exatamente uma entrega responde 200; a outra recebe 409 `already_picked_up`.
class ApiPickupDeliveryRaceTest < DatabaseTest
  include OperationsSupport

  def setup
    super
    @org = create_organization
    @actor = @org[:actor]
    @branch = @org[:branch]
    @customer = create_customer(@actor)
    camera = create_product(@actor, sku: "CAM-RACE", tracking: "serialized")
    register_assets(@actor, camera, @branch, 1)
    reservation = confirmed([line(camera, 1)])
    @pickup = uc(:start_pickup).call(@actor, reservation.id)
    uc(:check_pickup).call(@actor, @pickup.id, check_entries(@actor, @pickup))
    @token = uc(:create_credential).call(@actor, name: "Balcão", scopes: %w[fulfillment.write reservations.read], expires_in_days: 30)["token"]
    @app = Locentra::Interfaces::HTTP::App.build(@system)
  end

  def deliver(key)
    env = Rack::MockRequest.env_for("/api/v1/pickups/#{@pickup.id}/deliver", method: "POST", input: JSON.generate("picker" => { "kind" => "customer" }),
                                                                             "CONTENT_TYPE" => "application/json",
                                                                             "HTTP_AUTHORIZATION" => "Bearer #{@token}", "HTTP_IDEMPOTENCY_KEY" => key)
    status, _headers, body = @app.call(env)
    text = +""
    body.each { |part| text << part }
    body.close if body.respond_to?(:close)
    [status, JSON.parse(text)]
  end

  def test_exactly_one_delivery_succeeds
    barrier = Barrier.new(2)
    threads = %w[entrega-chave-a entrega-chave-b].map do |key|
      Thread.new do
        barrier.wait
        deliver(key)
      end
    end
    results = threads.map(&:value).sort_by(&:first)

    assert_equal [200, 409], results.map(&:first), results.inspect
    assert_equal %w[delivered already_picked_up], [results.first.last["status"], results.last.last["error"]["code"]]
    assert_equal 1, count("SELECT count(*) FROM outbox_events WHERE event_type = 'reservation.picked_up'")
    assert_equal 1, count("SELECT count(*) FROM audit_events WHERE action = 'reservation.picked_up'")
  end
end
