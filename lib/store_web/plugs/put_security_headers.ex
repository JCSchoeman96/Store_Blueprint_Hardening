defmodule StoreWeb.Plugs.PutSecurityHeaders do
  @moduledoc """
  Adds runtime-configured security headers for browser responses.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    config = Application.get_env(:store, :security_headers, [])
    csp_mode = Keyword.get(config, :csp_mode, :disabled)
    csp_policy = Keyword.get(config, :csp_policy)
    csp_report_uri = Keyword.get(config, :csp_report_uri)

    conn
    |> put_resp_header("referrer-policy", "strict-origin-when-cross-origin")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("x-frame-options", "SAMEORIGIN")
    |> maybe_put_csp(csp_mode, csp_policy, csp_report_uri)
  end

  defp maybe_put_csp(conn, :disabled, _policy, _report_uri), do: conn

  defp maybe_put_csp(conn, mode, policy, report_uri) when mode in [:enforce, :report_only] do
    policy =
      if is_binary(report_uri) and String.trim(report_uri) != "" do
        "#{policy}; report-uri #{report_uri}"
      else
        policy
      end

    header =
      case mode do
        :enforce -> "content-security-policy"
        :report_only -> "content-security-policy-report-only"
      end

    if is_binary(policy) and String.trim(policy) != "" do
      put_resp_header(conn, header, policy)
    else
      conn
    end
  end
end
