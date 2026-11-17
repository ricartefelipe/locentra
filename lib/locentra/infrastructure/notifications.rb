# frozen_string_literal: true

module Locentra
  module Infrastructure
    # Notificações transacionais enfileiradas na transação do negócio. O worker monta e envia o
    # e-mail; tokens de uso único são emitidos no envio para não ficarem gravados na fila.
    class JobNotifier
      def initialize(queue:)
        @queue = queue
      end

      def email_confirmation(tx, user_id)
        @queue.enqueue(tx, "email.confirmation", { "user_id" => user_id }, priority: 20)
      end

      def password_reset(tx, user)
        @queue.enqueue(tx, "email.password_reset", { "user_id" => user["id"] }, priority: 10)
      end

      def invitation(tx, invitation)
        @queue.enqueue(tx, "email.invitation", { "invitation_id" => invitation["id"] }, priority: 20)
      end

      def generic(tx, template, to:, variables: {})
        @queue.enqueue(tx, "email.send", { "template" => template, "to" => to, "variables" => variables }, priority: 60)
      end
    end
  end
end
