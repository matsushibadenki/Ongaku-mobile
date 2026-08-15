<?php
// /contact/send_mail.php

mb_language("Japanese");
mb_internal_encoding("UTF-8");

require_once('common_vars.php');
require_once('html_text.php'); // $html_template を読み込む（ユーザー宛テンプレート）

// --- フォームからのデータ受け取り ---
$name    = $_POST['name'] ? '未入力';
$email   = $_POST['email'] ? '';
$subject = $_POST['subject'] ? 'お問い合わせ';
$message = $_POST['message'] ? '';

// --- 管理者用メール送信設定 ---
$admin_to      = $TO;  // common_vars.php から読み込み
$admin_subject = "【お問い合わせ】" . $subject;
$admin_body    = <<<EOT
以下の内容でお問い合わせがありました。

お名前: {$name}
メールアドレス: {$email}
件名: {$subject}

本文:
{$message}
EOT;

// From: はサーバードメインの信頼されたアドレスにする（SPF/DMARC対策）
$headers_admin = "From: Webフォーム <{$admin_to}>\r\n";

// --- ユーザーへの自動返信メール設定 ---
$user_subject = "【自動返信】お問い合わせありがとうございます";
$user_body    = $html_template;  // html_text.php 内のテンプレート

$headers_user = "MIME-Version: 1.0\r\n";
$headers_user .= "Content-Type: text/html; charset=UTF-8\r\n";
$headers_user .= "From: お問い合わせ窓口 <{$admin_to}>\r\n";

// --- メール送信処理 ---

// 管理者宛メール送信
$admin_result = mb_send_mail($admin_to, $admin_subject, $admin_body, $headers_admin);

// ユーザー宛メール送信（HTMLテンプレート）
$user_result = false;
if (filter_var($email, FILTER_VALIDATE_EMAIL)) {
    $user_result = mb_send_mail($email, $user_subject, $user_body, $headers_user);
}

// --- ログ出力 ---
$log = "[送信ログ] " . date("Y-m-d H:i:s") . "\n";
$log .= "To Admin: {$admin_to} => " . ($admin_result ? "成功" : "失敗") . "\n";
$log .= "To User : {$email} => " . ($user_result ? "成功" : "失敗") . "\n";
$log .= str_repeat("-", 40) . "\n";
file_put_contents('mail_debug.log', $log, FILE_APPEND);

// --- 完了画面やリダイレクトなど ---
header('Location: thanks.html');
exit;
