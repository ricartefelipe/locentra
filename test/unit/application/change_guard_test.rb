# frozen_string_literal: true

require_relative "../unit_helper"

# Verificações de vínculo das reservas: a dispensa é explícita (`via:`) e vale somente para o
# vínculo do caso de uso que compõe a operação.
class ChangeGuardTest < UnitTest
  Guard = Locentra::Application::Reservations::ChangeGuard
  Linked = Data.define(:code)

  # Repositório em memória: devolve o documento vinculado e registra as consultas feitas.
  class Links
    attr_reader :queries

    def initialize(document)
      @document = document
      @queries = []
    end

    def holding(_tx, reservation_id) = lookup(:quote, reservation_id)
    def open_for_reservation(_tx, reservation_id) = lookup(:contract, reservation_id)

    private

    def lookup(kind, reservation_id)
      @queries << kind
      reservation_id == "r1" ? @document : nil
    end
  end

  def reservation(id: "r1") = Data.define(:id, :code).new(id: id, code: "R-000001")

  def guard(quote: nil, contract: nil)
    @quotes = Links.new(quote)
    @contracts = Links.new(contract)
    Guard.new(contracts: @contracts, quotes: @quotes)
  end

  def test_contract_link_is_skipped_only_when_composed_by_the_contract
    subject = guard(contract: Linked.new(code: "C-000001"))

    error = assert_raises(Domain::Conflict) { subject.ensure_changeable!(:tx, reservation, "cancel") }
    assert_equal "contract_amendment_required", error.code
    assert_includes error.message, "C-000001"
    assert_raises(Domain::Conflict) { subject.ensure_changeable!(:tx, reservation, "extend", via: :quote) }
    assert subject.ensure_changeable!(:tx, reservation, "cancel", via: :contract)
    assert subject.ensure_changeable!(:tx, reservation, "confirm"), "confirmação não depende do contrato"
    assert subject.ensure_changeable!(:tx, reservation(id: "r2"), "reschedule")
  end

  def test_quote_hold_blocks_confirmation_and_period_changes_but_not_cancellation
    subject = guard(quote: Linked.new(code: "Q-000001"))

    %w[confirm reschedule extend].each do |operation|
      error = assert_raises(Domain::Conflict, operation) { subject.ensure_changeable!(:tx, reservation, operation) }

      assert_equal "quote_hold", error.code
      assert_includes error.message, "Q-000001"
    end
    assert subject.ensure_changeable!(:tx, reservation, "cancel")
    assert subject.ensure_changeable!(:tx, reservation, "confirm", via: :quote)
    assert_equal 3, @quotes.queries.size, "cancelamento e composição pelo orçamento não consultam o bloqueio"
  end

  def test_unknown_composition_is_rejected
    assert_raises(ArgumentError) { guard.ensure_changeable!(:tx, reservation, "cancel", via: :api) }
  end
end
