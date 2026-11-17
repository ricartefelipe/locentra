# frozen_string_literal: true

require_relative "../unit_helper"

class AttachmentsRulesTest < UnitTest
  R = Locentra::Application::Attachments::Rules

  def test_detects_types_by_content_not_declared_name
    assert_equal "application/pdf", R.detect_type("%PDF-1.7\n...")
    assert_equal "image/png", R.detect_type("\x89PNG\r\n\x1A\nIHDR".b)
    assert_equal "image/jpeg", R.detect_type("\xFF\xD8\xFF\xE0JFIF".b)
    assert_equal "image/webp", R.detect_type("RIFF\x00\x00\x00\x00WEBPVP8 ".b)
    assert_nil R.detect_type("<html><script>alert(1)</script>")
    assert_nil R.detect_type("MZ\x90\x00executavel".b)
  end

  def test_sanitizes_filenames
    assert_equal "passwd", R.sanitize_filename("../../etc/passwd")
    assert_equal "contrato.pdf", R.sanitize_filename("C:\\Users\\x\\contrato.pdf")
    assert_equal "arquivo", R.sanitize_filename(".htaccess")
    assert_equal "arquivo", R.sanitize_filename("")
    assert_equal "notafiscal.pdf", R.sanitize_filename("nota\u0001fiscal.pdf")
    assert_operator R.sanitize_filename("a" * 500).length, :<=, 200
  end
end
