# frozen_string_literal: true

require_relative "integration_helper"

# Arquivo gravado por um upload composto com outra operação é removido quando a transação é desfeita
# depois do upload, inclusive quando o Transactor repete a transação por deadlock.
class AttachmentCleanupTest < DatabaseTest
  PDF = "%PDF-1.4\n%teste\n".b

  def setup
    super
    @org = create_organization
    @customer = create_customer(@org[:actor])
    FileUtils.rm_rf(File.join(@system.config.storage_root, @org[:organization_id]))
  end

  def stored_files = Dir.glob(File.join(@system.config.storage_root, @org[:organization_id], "*"))

  def upload(tx, actor)
    uc(:upload_attachment).call(actor, owner_type: "customer", owner_id: @customer.id, filename: "doc.pdf", bytes: PDF, tx: tx)
  end

  def test_failure_after_the_upload_removes_the_file
    assert_raises(RuntimeError) do
      @system.uow.run(@org[:actor], "customers.write") do |tx, actor|
        upload(tx, actor)
        raise "falha depois do upload"
      end
    end
    assert_empty stored_files
    assert_equal 0, owner_query("SELECT count(*) AS n FROM attachments").first["n"].to_i
  end

  def test_retried_transaction_keeps_only_the_committed_file
    attempts = 0
    row = @system.uow.run(@org[:actor], "customers.write") do |tx, actor|
      attempts += 1
      uploaded = upload(tx, actor)
      raise PG::TRDeadlockDetected, "deadlock simulado" if attempts == 1

      uploaded
    end

    assert_equal 2, attempts
    assert_equal [File.join(@system.config.storage_root, row["storage_key"])], stored_files
  end
end
