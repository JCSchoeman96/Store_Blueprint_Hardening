defmodule Store.Accounts.Emails do
  @moduledoc """
  Email delivery helpers for authentication workflows.
  """

  import Swoosh.Email

  @spec deliver_email_confirmation_instructions(map(), String.t()) ::
          {:ok, term()} | {:error, term()}
  def deliver_email_confirmation_instructions(user, url) do
    user
    |> email(
      "Confirm your account",
      """
      <p>Hi #{user.email},</p>
      <p>Please confirm your account by clicking the link below.</p>
      <p><a href="#{url}">Confirm account</a></p>
      """
    )
    |> Store.Mailer.deliver()
  end

  @spec deliver_identity_link_confirmation_instructions(map(), String.t(), atom() | String.t()) ::
          {:ok, term()} | {:error, term()}
  def deliver_identity_link_confirmation_instructions(user, url, provider) do
    provider_name = provider |> to_string() |> String.capitalize()

    user
    |> email(
      "Confirm linking your #{String.downcase(provider_name)} login",
      """
      <p>Someone signed in with #{provider_name} using your email address and wants to link it to your account.</p>
      <p>If this was you, confirm here to grant #{provider_name} sign-in access to your account: <a href="#{url}">Confirm identity link</a></p>
      <p>If it wasn't you, ignore this email - nothing has changed.</p>
      """
    )
    |> Store.Mailer.deliver()
  end

  @spec deliver_reset_password_instructions(map(), String.t()) :: {:ok, term()} | {:error, term()}
  def deliver_reset_password_instructions(user, url) do
    user
    |> email(
      "Reset your password",
      """
      <p>Hi #{user.email},</p>
      <p>Use the link below to reset your password.</p>
      <p><a href="#{url}">Reset password</a></p>
      """
    )
    |> Store.Mailer.deliver()
  end

  defp email(user, subject, html_body) do
    new()
    |> to(to_string(user.email))
    |> from({"Store", "no-reply@store.local"})
    |> subject(subject)
    |> html_body(html_body)
  end
end
