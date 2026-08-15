<?php
// タイトル: お問い合わせフォーム処理
// タイトル: お問い合わせフォーム処理
// 役割: フォームデータの検証、reCAPTCHA検証、メール送信（管理者宛・ユーザーへの自動返信）を行う。

ini_set('display_errors', 1);
ini_set('display_startup_errors', 1);
error_reporting(E_ALL);

require 'libs/recaptcha_vars.php';
require 'libs/validation.php';
require 'libs/recaptcha.php';
require 'libs/send_email.php';
require 'libs/common_vars.php';
require 'libs/html_text.php';

// mbstring関数の設定
// ◾️◾️◾️◾️◾️◾️◾️◾️◾️◾️◾️↓修正開始◾️◾️◾️◾️◾️◾️◾️◾️◾️◾️◾️
// send_email.php内で設定されるため、ここでの重複設定は削除
/*
if (function_exists('mb_language')) {
    mb_language("uni");
    mb_internal_encoding("UTF-8");
}
*/
// ◾️◾️◾️◾️◾️◾️◾️◾️◾️◾️◾️↑修正終わり◾️◾️◾️◾️◾️◾️◾️◾️◾️◾️◾️

// reCAPTCHAキーを変数に設定
$siteKey = V3_SITEKEY;
$secretKey = V3_SECRETKEY;

// フォームがPOSTされた場合の処理
if ($_SERVER['REQUEST_METHOD'] == 'POST') {
    // バリデーションの実行
    $errors = validate_form_data($_POST, 'general');

    // エラーがなかった場合の処理
    if (empty($errors)) {
        // reCAPTCHAの検証
        $recaptcha_response = isset($_POST['g-recaptcha-response']) ? $_POST['g-recaptcha-response'] : '';
        $result = verify_recaptcha($recaptcha_response, $secretKey, $_SERVER['REMOTE_ADDR']);

        // reCAPTCHAの検証が成功した場合の処理
        if ($result['success'] && $result['score'] >= 0.5 && $result['action'] == 'contact') {

            // POSTデータを安全な変数に格納
            $name1 = isset($_POST['name1']) ? trim($_POST['name1']) : '';
            $name2 = isset($_POST['name2']) ? trim($_POST['name2']) : '';
            $name = $name1 . ' ' . $name2;

            $email = isset($_POST['email1']) ? trim($_POST['email1']) : '';
            $message = isset($_POST['message']) ? trim($_POST['message']) : '';

            $remote_ip = $_SERVER['REMOTE_ADDR'];

            // --------------------------------
            // 1. サイト管理者への通知メール送信
            // --------------------------------

            $admin_subject = '【' . $site_name . ' 問い合わせ】' . $name . ' 様より';

            $admin_body = "Webサイトの問い合わせフォームから連絡がありました。\n\n";
            $admin_body .= "--------------------------------------------------\n";
            $admin_body .= "お名前： " . $name . "\n";
            $admin_body .= "E-Mail： " . $email . "\n\n";
            $admin_body .= "メッセージ本文：\n" . $message . "\n";
            $admin_body .= "--------------------------------------------------\n";
            $admin_body .= "送信元IPアドレス： " . $remote_ip . "\n";

            // $to と $bcc は common_vars.php で定義
            // 送信元としてサイトの情報を指定し、Reply-Toにユーザーのメールアドレスを設定する
            $admin_from_name = $site_name . ' ウェブサイト';
            $admin_from_email = $sender_email;
            $is_admin_sent = send_email($to, $admin_subject, $admin_body, $admin_from_name, $admin_from_email, $bcc, $email);

            if ($is_admin_sent) {
                if (isset($_SERVER['HTTP_X_REQUESTED_WITH']) && strtolower($_SERVER['HTTP_X_REQUESTED_WITH']) == 'xmlhttprequest') {
                    $response = [
                        'status' => 'success',
                        'message' => '送信完了いたしました。お問い合わせいただき、ありがとうございました。',
                        'sub_message' => 'ご入力いただいたメールアドレスに、確認のメールを自動送信いたしました。'
                    ];
                } else {
                    echo '<div class="alert alert-success alert-dismissible" role="alert">送信完了いたしました。お問い合わせいただき、ありがとうございました。</div>';
                }

                // --------------------------------
                // 2. ユーザーへの自動返信メール送信
                // --------------------------------

                $reply_subject = '【' . $site_name . '】お問い合わせありがとうございます';
                $reply_body = get_auto_reply_text($name);

                // 送信元としてサイトの正式名称とアドレスを指定する
                $reply_from_name = $site_name . ' サポート';
                $reply_from_email = $sender_email;

                $is_reply_sent = send_email($email, $reply_subject, $reply_body, $reply_from_name, $reply_from_email);

                if (!$is_reply_sent) {
                    error_log("ユーザーへの自動返信メールの送信に失敗しました。宛先: " . $email . " - 日時: " . date('Y-m-d H:i:s'));
                }

                if (isset($response)) {
                    header('Content-Type: application/json');
                    echo json_encode($response);
                    exit;
                } else {
                    echo '<div class="alert alert-success alert-dismissible mt-3" role="alert">ご入力いただいたメールアドレスに、確認のメールを自動送信いたしました。</div>';
                }
            } else {
                if (isset($_SERVER['HTTP_X_REQUESTED_WITH']) && strtolower($_SERVER['HTTP_X_REQUESTED_WITH']) == 'xmlhttprequest') {
                    header('Content-Type: application/json');
                    echo json_encode(['status' => 'error', 'message' => 'メッセージの送信に失敗しました。サーバーに問題が発生している可能性があります。']);
                    exit;
                } else {
                    echo '<div class="alert alert-danger alert-dismissible mt-3" role="alert">メッセージの送信に失敗しました。サーバーに問題が発生している可能性があります。恐れ入りますが、時間をおいて再度お試しください。</div>';
                }
            }
        } else {
            $recaptcha_errors = isset($result['error-codes']) ? implode(', ', $result['error-codes']) : '不明なエラー';
            if (isset($_SERVER['HTTP_X_REQUESTED_WITH']) && strtolower($_SERVER['HTTP_X_REQUESTED_WITH']) == 'xmlhttprequest') {
                header('Content-Type: application/json');
                echo json_encode(['status' => 'error', 'message' => 'reCAPTCHA認証に失敗しました。 (エラー: ' . $recaptcha_errors . ')']);
                exit;
            } else {
                echo '<div class="alert alert-danger alert-dismissible" role="alert">reCAPTCHA認証に失敗しました。ボットでない場合は、時間をおいて再度お試しください。 (エラー: ' . htmlspecialchars($recaptcha_errors) . ')</div>';
            }
        }
    } else {
        if (isset($_SERVER['HTTP_X_REQUESTED_WITH']) && strtolower($_SERVER['HTTP_X_REQUESTED_WITH']) == 'xmlhttprequest') {
            header('Content-Type: application/json');
            echo json_encode(['status' => 'validation_error', 'errors' => $errors]);
            exit;
        } else {
            $errorOutput = '<div class="alert alert-danger alert-dismissible" role="alert">';
            $errorOutput .= '<strong>入力内容にエラーがあります。</strong>';
            $errorOutput .= '<ul>';

            foreach ($errors as $value) {
                $errorOutput .= '<li>' . htmlspecialchars($value) . '</li>';
            }

            $errorOutput .= '</ul>';
            $errorOutput .= '</div>';

            echo $errorOutput;
        }
    }
}
