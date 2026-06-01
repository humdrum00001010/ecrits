defmodule Contract.Accounts.UserNotifier do
  @moduledoc """
  Builds and dispatches legacy auth emails.

  Oban was removed with the DB substrate, so these functions send directly.
  Auth routes are retired, but keeping this module DB-free lets old callers
  compile during the local-first migration.
  """
  import Swoosh.Email

  alias Contract.Mailer
  alias Contract.Accounts
  alias Contract.Accounts.User

  @doc """
  Deliver update email instructions.
  """
  def deliver_update_email_instructions(%User{} = user, url) when is_binary(url) do
    deliver_now(user.email, "이메일 변경 안내 · 계약기계", update_email_body(user, url))
  end

  @doc """
  Deliver login instructions.
  """
  def deliver_login_instructions(%User{} = user, url) when is_binary(url) do
    case user do
      %User{confirmed_at: nil} ->
        deliver_now(user.email, "계정 확인 안내 · 계약기계", confirmation_body(user, url))

      _ ->
        deliver_now(user.email, "로그인 안내 · 계약기계", magic_link_body(user, url))
    end
  end

  # ---------------------------------------------------------------------------
  # Worker entry points — retained for legacy tests/callers.
  # Each takes a JSON-decoded args map, re-fetches the user, builds the
  # email, and calls Mailer.deliver/1.
  # ---------------------------------------------------------------------------

  @doc false
  def perform_update_email_instructions(%{"user_id" => user_id, "url" => url}) do
    user = Accounts.get_user!(user_id)
    deliver_now(user.email, "이메일 변경 안내 · 계약기계", update_email_body(user, url))
  end

  @doc false
  def perform_login_instructions(%{"user_id" => user_id, "url" => url}) do
    user = Accounts.get_user!(user_id)

    case user do
      %User{confirmed_at: nil} ->
        perform_confirmation_instructions(%{"user_id" => user_id, "url" => url})

      _ ->
        perform_magic_link_instructions(%{"user_id" => user_id, "url" => url})
    end
  end

  @doc false
  def perform_confirmation_instructions(%{"user_id" => user_id, "url" => url}) do
    user = Accounts.get_user!(user_id)
    deliver_now(user.email, "계정 확인 안내 · 계약기계", confirmation_body(user, url))
  end

  @doc false
  def perform_magic_link_instructions(%{"user_id" => user_id, "url" => url}) do
    user = Accounts.get_user!(user_id)
    deliver_now(user.email, "로그인 안내 · 계약기계", magic_link_body(user, url))
  end

  # ---------------------------------------------------------------------------
  # Internals — actual SMTP send + body templates.
  # ---------------------------------------------------------------------------

  defp deliver_now(recipient, subject, body) do
    email =
      new()
      |> to(recipient)
      |> from(Mailer.from())
      |> subject(subject)
      |> text_body(body.text)
      |> html_body(body.html)

    with {:ok, _metadata} <- Mailer.deliver(email) do
      {:ok, email}
    end
  end

  defp update_email_body(user, url) do
    intro = "계약기계에서 이메일 주소 변경을 요청하셨습니다. 아래 버튼을 눌러 새 이메일을 확정해 주세요."
    disclaimer = "본인이 요청하지 않았다면 이 메일은 무시하셔도 됩니다."

    %{
      text: text_body(user, intro, url, disclaimer),
      html: email_html_body(intro, url, "이메일 변경하기", disclaimer)
    }
  end

  defp magic_link_body(user, url) do
    intro = "계약기계에 로그인하려면 아래 버튼을 눌러주세요. 이 링크는 일회용이며 한 시간 안에 만료됩니다."
    disclaimer = "본인이 요청하지 않았다면 이 메일은 무시하셔도 됩니다."

    %{
      text: text_body(user, intro, url, disclaimer),
      html: email_html_body(intro, url, "로그인하기 →", disclaimer)
    }
  end

  defp confirmation_body(user, url) do
    intro = "계약기계 가입을 환영합니다. 아래 버튼을 눌러 계정을 확정해 주세요."
    disclaimer = "본인이 가입을 시도하지 않았다면 이 메일은 무시하셔도 됩니다."

    %{
      text: text_body(user, intro, url, disclaimer),
      html: email_html_body(intro, url, "계정 확인하기", disclaimer)
    }
  end

  defp text_body(user, intro, url, disclaimer) do
    """
    계약기계

    #{user.email}님,

    #{intro}

    #{url}

    #{disclaimer}

    —
    계약기계 · 비공개 베타
    """
  end

  defp email_html_body(intro, url, link_text, disclaimer) do
    # Inline-only CSS — many mail clients strip <style> tags.
    bg = "#FAFAF7"
    surface = "#FFFFFF"
    ink = "#171717"
    muted = "#6B7280"
    line = "#E5E7EB"
    accent = "#1F6B48"
    accent_hover = "#2F7C58"
    link_frame_attrs = email_link_frame_attrs()

    """
    <!DOCTYPE html>
    <html lang="ko">
    <body style="margin:0; padding:24px 16px; background:#{bg}; font-family:-apple-system, BlinkMacSystemFont, 'Pretendard', 'Noto Sans KR', 'Apple SD Gothic Neo', system-ui, sans-serif; color:#{ink}; line-height:1.6;">
      <table role="presentation" cellspacing="0" cellpadding="0" border="0" align="center" width="100%" style="max-width:520px; margin:0 auto;">
        <tr>
          <td style="padding:8px 4px 24px; font-size:13px; letter-spacing:0.16em; text-transform:uppercase; color:#{muted}; font-weight:600;">
            계약기계
          </td>
        </tr>
        <tr>
          <td style="background:#{surface}; border:1px solid #{line}; border-radius:10px; padding:32px 32px 28px;">
            <p style="margin:0 0 20px; font-size:15px; line-height:1.7; color:#{ink};">
              #{intro}
            </p>

            <p style="margin:0 0 24px;">
              <a href="#{url}"#{link_frame_attrs} style="display:inline-block; padding:11px 20px; background:#{accent}; color:#FFFFFF; font-size:14px; font-weight:600; text-decoration:none; border-radius:6px; border:1px solid #{accent_hover};">
                #{link_text}
              </a>
            </p>

            <p style="margin:0 0 4px; font-size:12px; color:#{muted};">버튼이 동작하지 않으면 이 주소를 브라우저에 붙여넣으세요:</p>
            <p style="margin:0 0 0; font-size:12px;">
              <a href="#{url}"#{link_frame_attrs} style="color:#{accent}; word-break:break-all; text-decoration:underline;">#{url}</a>
            </p>
          </td>
        </tr>
        <tr>
          <td style="padding:20px 4px 0; font-size:12px; color:#{muted}; line-height:1.6;">
            #{disclaimer}
            <br />
            <span style="color:#{muted}/0.6;">— 계약기계 · 비공개 베타</span>
          </td>
        </tr>
      </table>
    </body>
    </html>
    """
  end

  defp email_link_frame_attrs do
    if Application.get_env(:contract, :dev_routes, false) do
      ""
    else
      ~s( target="_top" rel="noopener noreferrer")
    end
  end
end
