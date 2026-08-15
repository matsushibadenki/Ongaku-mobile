<?php
function send_email($to, $subject, $body, $from, $bcc = '') {
    $sendermail = 'no-reply@ts-ikusya.com';

    // ヘッダーの構築
    $headers = '';
    $headers .= "Date: " . date('r') . "\r\n";
    $headers .= "From: " . $sendermail . "\r\n";
    $headers .= "Content-Type: text/plain; charset=UTF-8\r\n";
    $headers .= "MIME-Version: 1.0\r\n";
    $headers .= "Content-Transfer-Encoding: 8bit\r\n";
    if (!empty($bcc)) {
        $headers .= "Bcc: " . $bcc . "\r\n";
    }

    // Return-Path の指定（第五引数）
    $param = "-f" . $sendermail;

    // メール送信
    return mail($to, $subject, $body, $headers, $param);
}
?>
