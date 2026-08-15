<?php
ini_set('display_errors', 1);
ini_set('display_startup_errors', 1);
error_reporting(E_ALL);

mb_language("uni");
mb_internal_encoding("UTF-8");

require 'libs/recaptcha_vars.php';
require 'libs/validation.php';
require 'libs/recaptcha.php';
require 'libs/send_email.php';
require 'libs/common_vars.php';
require 'libs/html_text.php';

$siteKey = V3_SITEKEY;
$secretKey = V3_SECRETKEY;

if ($_SERVER['REQUEST_METHOD'] == 'POST') {
    $errors = validate_form_data($_POST, 'general');

    if (empty($errors)) {
        $result = verify_recaptcha($_POST['g-recaptcha-response'], $secretKey, $_SERVER['REMOTE_ADDR']);

        if ($result['success'] && $result['score'] >= 0.5 && $result['action'] == 'contact') {

            $name = $_POST['name1'] . ' ' . $_POST['name2'];
            $email = $_POST['email1'];
            $message = $_POST['message'];
            $companyname = $_POST['companyname'];
            $department = $_POST['department'];
            $position = $_POST['position'];
            $tel = $_POST['tel1'] . '-' . $_POST['tel2'] . '-' . $_POST['tel3'];
            $remote_ip = $_SERVER['REMOTE_ADDR'];

            $body = "送信者： $name\n";
            $body .= "E-Mail： $email\n";
            $body .= "IP-address： $remote_ip\n";
            $body .= "会社名： $companyname\n";
            $body .= "部署： $department\n";
            $body .= "役職： $position\n";
            $body .= "電話番号： $tel\n";
            $body .= "メッセージ： \n$message\n";
            $body = mb_convert_kana($body, "a");

            $subject = '【' . $name . ' 様】徳志育舎　お問い合わせ';
            $subject = "=?UTF-8?B?" . base64_encode($subject) . "?=";

            if (send_email($to, $subject, $body, $email, $bcc)) {
                echo '<div class="alert alert-success alert-dismissible" role="alert">送信完了いたしました。お問い合わせいただき、ありがとうございました。</div>';
                // 自動返信メールの本文作成
                $reply_subject = '【' . $name . ' 様】お問い合わせありがとうございます';
                $reply_subject = "=?UTF-8?B?" . base64_encode($reply_subject) . "?=";

                // `html_text.php` からテンプレートを取得
                $reply_body = htmlspecialchars(get_auto_reply_text($name)); // エスケープ処理を追加

                // 自動返信メール送信
                if (send_email($email, $reply_subject, $reply_body, $to)) {
                    echo '<div class="alert alert-success alert-dismissible mt-5" role="alert">自動返信メールが送信されました。</div>';
                } else {
                    echo '<div class="alert alert-danger alert-dismissible" role="alert">自動返信メールの送信中に問題が発生しました。</div>';
                }
            } else {
                echo '<div class="alert alert-danger alert-dismissible mt-3" role="alert">このメッセージの送信中に問題が起こったようです。後でもう一度お試しください。</div>';
            }
        } else {
            echo '<div class="alert alert-danger alert-dismissible" role="alert">reCAPTCHAの検証に失敗しました。</div>';
        }
    } else {
        $errorOutput = '<div class="alert alert-danger alert-dismissible" role="alert">';
        $errorOutput .= '<span aria-hidden="true">&times;</span>';
        $errorOutput .= '<ul>';

        foreach ($errors as $value) {
            $errorOutput .= '<li>' . $value . '</li>';
        }

        $errorOutput .= '</ul>';
        $errorOutput .= '</div>';

        echo $errorOutput;
    }
}
