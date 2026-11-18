# frozen_string_literal: true

module Locentra
  module Infrastructure
    # Notificações transacionais enfileiradas na transação do negócio. O worker monta e envia o
    # e-mail; tokens de uso único são emitidos no envio para não ficarem gravados na fila. A tarefa
    # recebe o request_id da transação (do ator ou, em fluxos sem ator, o informado à unidade de
    # trabalho) como correlation_id.
    class JobNotifier
      def initialize(queue:)
        @queue = queue
      end

      def email_confirmation(tx, user_id)
        @queue.enqueue(tx, "email.confirmation", { "user_id" => user_id }, priority: 20, correlation_id: correlation(tx))
      end

      def password_reset(tx, user)
        @queue.enqueue(tx, "email.password_reset", { "user_id" => user["id"] }, priority: 10, correlation_id: correlation(tx))
      end

      def invitation(tx, invitation)
        @queue.enqueue(tx, "email.invitation", { "invitation_id" => invitation["id"] }, priority: 20, correlation_id: correlation(tx))
      end

      def portal_invitation(tx, invitation)
        @queue.enqueue(tx, "email.portal_invitation", { "invitation_id" => invitation.id }, priority: 20)
      end

      def generic(tx, template, to:, variables: {})
        @queue.enqueue(tx, "email.send", { "template" => template, "to" => to, "variables" => variables }, priority: 60, correlation_id: correlation(tx))
      end

      private

      def correlation(tx) = tx.request_id
    end
  end
end
