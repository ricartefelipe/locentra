# frozen_string_literal: true

module Locentra
  module Interfaces
    module HTTP
      # Rótulos em português de códigos internos exibidos nas telas (origem da reserva, tipos de ajuste e
      # de evento, situações sem mapa no domínio) e dos campos citados no resumo de erros. Código sem
      # rótulo aparece legível (sublinhado vira espaço), nunca como chave técnica crua.
      module Labels
        GROUPS = {
          reservation_source: { "staff" => "Equipe", "quote" => "Orçamento", "api" => "API", "portal" => "Portal do cliente" },
          adjustment_kind: { "extension" => "Extensão", "late_fee" => "Multa por atraso", "cancellation_fee" => "Taxa de cancelamento",
                             "damage" => "Avaria" },
          asset_event: {
            "registered" => "Cadastro", "status_changed" => "Mudança de situação", "checked_out" => "Retirada pelo cliente",
            "returned" => "Devolução", "inspection_approved" => "Inspeção aprovada", "maintenance_opened" => "Manutenção aberta",
            "maintenance_started" => "Manutenção iniciada", "maintenance_completed" => "Manutenção concluída",
            "maintenance_cancelled" => "Manutenção cancelada", "transfer_dispatched" => "Saída para transferência",
            "transfer_received" => "Recebimento de transferência"
          },
          subscription_status: { "trialing" => "Em avaliação", "active" => "Ativa", "past_due" => "Em atraso", "suspended" => "Suspensa",
                                 "cancelled" => "Cancelada" },
          delivery_status: { "pending" => "Pendente", "delivered" => "Entregue", "failed" => "Falhou" },
          environment: { "sandbox" => "Sandbox (testes)", "production" => "Produção" },
          audit_action: {
            "reservation.created" => "Reserva registrada", "reservation.confirmed" => "Reserva confirmada",
            "reservation.cancelled" => "Reserva cancelada", "reservation.expired" => "Bloqueio temporário expirado",
            "reservation.extended" => "Reserva estendida", "reservation.rescheduled" => "Reserva reagendada",
            "reservation.overdue" => "Atraso na devolução", "reservation.picked_up" => "Retirada", "reservation.returned" => "Devolução",
            "quote.created" => "Orçamento criado", "quote.revised" => "Nova versão do orçamento", "quote.sent" => "Orçamento enviado",
            "quote.approved" => "Orçamento aprovado", "quote.rejected" => "Orçamento recusado", "quote.expired" => "Orçamento expirado",
            "quote.converted" => "Orçamento convertido em reserva", "contract.issued" => "Contrato emitido",
            "contract.accepted" => "Aceite do contrato", "contract.amended" => "Aditivo emitido", "contract.cancelled" => "Contrato cancelado",
            "contract.closed" => "Contrato encerrado"
          },
          actor_type: { "user" => "Usuário", "api" => "Integração (API)", "cli" => "CLI", "system" => "Sistema", "customer" => "Cliente (portal)" },
          field: {
            "nome" => "Nome", "email" => "E-mail", "senha" => "Senha", "organizacao" => "Nome da empresa", "plano" => "Plano",
            "documento" => "Documento", "tipo" => "Tipo", "inicio" => "Início", "fim" => "Fim", "quantidade" => "Quantidade",
            "produto" => "Produto", "cliente" => "Cliente", "filial" => "Filial", "desconto" => "Desconto", "cupom" => "Cupom",
            "caucao" => "Caução", "validade" => "Validade", "validade_bloqueio" => "Validade do bloqueio",
            "modalidade_diaria" => "Modalidade da diária", "custo_reposicao" => "Custo de reposição", "custo_aquisicao" => "Custo de aquisição",
            "data_aquisicao" => "Data de aquisição", "preco_hora" => "Preço por hora", "preco_diaria" => "Preço da diária",
            "preco_semana" => "Preço semanal", "faixas" => "Faixas de desconto", "precos" => "Preços", "situacao" => "Situação",
            "versao" => "Versão", "observacoes" => "Observações", "evidencias" => "Evidências", "decisao" => "Decisão",
            "cobranca" => "Cobrança", "identificador" => "Identificador", "valor" => "Valor", "custo" => "Custo",
            "custo_estimado" => "Custo estimado", "descricao" => "Descrição", "motivo" => "Motivo", "metodo" => "Forma de pagamento",
            "pago_em" => "Pago em", "vencimento" => "Vencimento", "chave_api" => "Chave de API", "ambiente" => "Ambiente",
            "provedor" => "Provedor", "escopos" => "Escopos", "papel" => "Papel", "token" => "Link", "items" => "Itens",
            "deslocamento" => "Deslocamento", "limite" => "Limite", "paginacao" => "Paginação", "arquivo" => "Arquivo",
            "severidade" => "Severidade", "patrimonio" => "Patrimônio", "codigo" => "Código", "endereco" => "Endereço",
            "telefone" => "Telefone", "periodo" => "Período"
          }
        }.freeze

        module_function

        def label(group, value)
          text = value.to_s
          GROUPS.fetch(group).fetch(text) { text.tr("_.", "  ").capitalize }
        end
      end
    end
  end
end
