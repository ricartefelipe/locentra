# frozen_string_literal: true

require_relative "../unit_helper"

# A matriz publicada em docs/PERMISSOES.md é conferida contra a fonte única
# (Domain::Identity::PERMISSIONS): mesmas permissões, na mesma ordem, com os mesmos papéis marcados.
class PermissionsDocTest < UnitTest
  Identity = Domain::Identity
  DOCUMENT = File.expand_path("../../../docs/PERMISSOES.md", __dir__)
  ROW = /\A\| `(?<permission>[a-z_.]+)` \|(?<cells>.*)\|\z/

  def document = @document ||= File.read(DOCUMENT, encoding: "UTF-8")

  # Permissão => papéis marcados com "✓", na ordem das colunas da tabela.
  def documented
    document.lines.filter_map { |line| ROW.match(line.strip) }.to_h do |row|
      cells = row[:cells].split("|", -1).map(&:strip)
      [row[:permission], Identity::ROLES.keys.zip(cells).filter_map { |role, cell| role if cell == "✓" }]
    end
  end

  def test_header_lists_the_roles_in_the_order_of_the_matrix
    header = document.lines.find { |line| line.start_with?("| Permissão |") }

    assert_equal ["Permissão", *Identity::ROLES.values], header.strip.split("|").map(&:strip).reject(&:empty?)
  end

  def test_every_permission_is_documented_in_the_order_of_the_matrix
    assert_equal Identity::PERMISSIONS.keys, documented.keys
  end

  def test_marked_roles_match_the_matrix
    table = documented

    Identity::PERMISSIONS.each do |permission, roles|
      assert_equal Identity::ROLES.keys & roles, table.fetch(permission), permission
    end
  end

  def test_cells_are_only_marked_or_empty
    cells = document.lines.filter_map { |line| ROW.match(line.strip) }.flat_map { |row| row[:cells].split("|", -1).map(&:strip) }

    assert_equal ["", "✓"], cells.uniq.sort
    assert_equal Identity::PERMISSIONS.size * Identity::ROLES.size, cells.size
  end

  def test_manual_discount_limits_are_documented
    limits = Identity::DISCOUNT_LIMITS_BPS.map { |role, bps| "#{Identity.role_label(role)} #{Domain::Percent.label(bps)}" }.join(", ")

    assert_includes document, "Desconto manual máximo: #{limits}; demais papéis: 0%."
  end
end
