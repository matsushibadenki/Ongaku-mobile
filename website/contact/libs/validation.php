<?php
function validate_form_data($data, $type)
{
    $errors = array();

    // 共通の検証項目
    if (empty($data['name1'])) {
        $errors['name1'] = 'あなたの苗字を入力してください';
    }

    if (empty($data['name2'])) {
        $errors['name2'] = 'あなたの名前を入力してください';
    }

    // 特定のフォームの検証項目
    switch ($type) {
        case 'common':
            // ---------------------------
            // 
            // ---------------------------
            if (empty($data['name3'])) {
                $errors['name3'] = '苗字のふりがなを入力してください';
            }

            if (empty($data['name4'])) {
                $errors['name4'] = '名前のふりがなを入力してください';
            }

            if (!isset($data['email1']) || !filter_var($data['email1'], FILTER_VALIDATE_EMAIL)) {
                $errors['email1'] = '正しいemailアドレスを入力してください';
            }

            if (!isset($data['email2']) || !filter_var($data['email2'], FILTER_VALIDATE_EMAIL)) {
                $errors['email2'] = '正しいemail（確認）アドレスを入力してください';
            }

            if ($data['email1'] !== $data['email2']) {
                $errors['email2'] = 'emailアドレスと確認用emailアドレスが一致しません';
            }


            break;

        case 'general':
            // ---------------------------
            // 一般用
            // ---------------------------

            if (!isset($data['email1']) || !filter_var($data['email1'], FILTER_VALIDATE_EMAIL)) {
                $errors['email1'] = '正しいメールアドレスを入力してください';
            }

            if (empty($data['message'])) {
                $errors['message'] = 'メッセージを入力してください';
            }

            if (!isset($data['kojin'])) {
                $errors['kojin'] = '個人情報保護方針に同意してください';
            }

            break;
    }

    return $errors;
}
