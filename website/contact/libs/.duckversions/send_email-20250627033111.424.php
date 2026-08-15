// /home/r9885488/public_html/ts-ikusya.com/jp/wp-content/themes/tokushiikusya/form/contact/libs/send_email.php
// タイトル: メール送信機能
// 役割: 指定された宛先にメールを送信する。mb_send_mailを使用して日本語メールを安全に送信する。

<?php
/**
 * メールを送信する
 *
 * @param string $to 宛先メールアドレス
 * @param string $subject 件名 (UTF-8)
 * @param string $body 本文 (UTF-8)
 * @param string $from_name 送信者名 (例: "山田 太郎")
 * @param string $from_email 送信元メールアドレス (例: "user@example.com")
 * @param string $bcc BCCメールアドレス (オプション)
 * @param string $reply_to_email Reply-Toに設定するメールアドレス (オプション)
 * @return bool 送信が成功したかどうか
 */
// ◾️◾️◾️◾️◾️◾️◾️◾️◾️◾️◾️↓修正開始◾️◾️◾️◾️◾️◾️◾️◾️◾️◾️◾️
function send_email($to, $subject, $body, $from_name, $from_email, $bcc = '', $reply_to_email = '') {
// ◾️◾️◾️◾️◾️◾️◾️◾️◾️◾️◾️↑修正終わり◾️◾️◾️◾️◾️◾️◾️◾️◾️◾️◾️
    // mb_send_mailのために言語と内部エンコーディングを設定
    if (function_exists('mb_language')) {
        mb_language('Japanese');
        mb_internal_encoding('UTF-8');
    }

    // ヘッダーの構築
    $headers = '';
    // Fromヘッダーをエンコードして設定 (mb_encode_mimeheaderで日本語の表示名に対応)
    $headers .= "From: " . mb_encode_mimeheader($from_name, 'UTF-8', 'B') . " <" . $from_email . ">\r\n";

    // ◾️◾️◾️◾️◾️◾️◾️◾️◾️◾️◾️↓修正開始◾️◾️◾️◾️◾️◾️◾️◾️◾️◾️◾️
    // Reply-Toヘッダーを設定すると、受信者が「返信」した際の宛先を制御できる
    if (!empty($reply_to_email)) {
        $headers .= "Reply-To: " . $reply_to_email . "\r\n";
    } else {
        $headers .= "Reply-To: " . $from_email . "\r\n";
    }
    // ◾️◾️◾️◾️◾️◾️◾️◾️◾️◾️◾️↑修正終わり◾️◾️◾️◾️◾️◾️◾️◾️◾️◾️◾️
    
    // Bccヘッダー
    if (!empty($bcc)) {
        $headers .= "Bcc: " . $bcc . "\r\n";
    }

    // Return-Path の指定（第五引数）。バウンスメールの宛先となり、SPF認証にも重要。
    // 送信元メールアドレス($from_email)を指定する。
    $param = "-f" . $from_email;

    // メール送信
    // mb_send_mail は件名・本文を自動でエンコードし、適切なヘッダーを付与する
    return mb_send_mail($to, $subject, $body, $headers, $param);
}
?>