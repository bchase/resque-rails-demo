require 'test_helper'

class ExportsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @export = exports(:one)
  end

  test "should get index" do
    get exports_url
    assert_response :success
  end

  test "should get new" do
    get new_export_url
    assert_response :success
  end

  test "should create export" do
    assert_difference('Export.count') do
      post exports_url, params: { export: { complete: @export.complete } }
    end

    assert_redirected_to export_url(Export.last)
  end

  test "should show export" do
    get export_url(@export)
    assert_response :success
  end

  test "should get edit" do
    get edit_export_url(@export)
    assert_response :success
  end

  test "should update export" do
    patch export_url(@export), params: { export: { complete: @export.complete } }
    assert_redirected_to export_url(@export)
  end

  test "should destroy export" do
    assert_difference('Export.count', -1) do
      delete export_url(@export)
    end

    assert_redirected_to exports_url
  end
end
