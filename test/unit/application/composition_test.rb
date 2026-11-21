# frozen_string_literal: true

require_relative "../unit_helper"

# Execução com transação própria ou composta (Application::Composition): sem transação, a unidade de
# trabalho abre a transação e confere a permissão; com a transação do chamador, a permissão é conferida
# sobre o ator recebido e a unidade de trabalho não é chamada.
class CompositionTest < UnitTest
  A = Locentra::Application
  ORG_ID = "00000000-0000-7000-8000-0000000000a1"

  class Uow
    attr_reader :calls

    def initialize = @calls = []

    def run(actor, permission = nil)
      @calls << [actor.kind, permission]
      yield :own_tx, actor
    end
  end

  def credential(scopes) = A::Actor.credential(kind: "api", credential_id: "c1", organization_id: ORG_ID, scopes: scopes)

  def test_without_transaction_delegates_to_the_unit_of_work
    uow = Uow.new
    result = A::Composition.run(uow, credential(%w[quotes.write]), "quotes.write", nil) { |tx, actor| [tx, actor.credential_id] }

    assert_equal [:own_tx, "c1"], result
    assert_equal [%w[api quotes.write]], uow.calls
  end

  def test_with_transaction_checks_the_permission_and_does_not_open_another
    uow = Uow.new
    result = A::Composition.run(uow, credential(%w[quotes.write]), "quotes.write", :caller_tx) { |tx, actor| [tx, actor.credential_id] }

    assert_equal [:caller_tx, "c1"], result
    assert_empty uow.calls
    error = assert_raises(Locentra::Domain::AccessDenied) do
      A::Composition.run(uow, credential(%w[quotes.read]), "quotes.write", :caller_tx) { flunk "o bloco não pode rodar sem a permissão" }
    end

    assert_equal "permissão necessária: quotes.write", error.message
    assert_empty uow.calls
  end

  def test_without_permission_the_block_runs_in_the_given_transaction
    uow = Uow.new

    assert_equal :caller_tx, A::Composition.run(uow, credential([]), nil, :caller_tx) { |tx, _| tx }
    assert_equal :own_tx, A::Composition.run(uow, credential([]), nil, nil) { |tx, _| tx }
    assert_equal [["api", nil]], uow.calls
  end
end
