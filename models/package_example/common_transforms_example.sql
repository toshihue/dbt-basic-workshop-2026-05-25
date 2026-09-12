{#
    common_transforms v1.2.0 の integration_tests を利用側向けにしたサンプル。

    処理の流れ:
      1. seed でロードした、表記揺れや欠損を含む会員データを読み込む
      2. common_transforms のマクロで文字列、コード、NULL を標準化する
      3. 識別子を組み立て、定数列と dbt 実行時の監査列を付与する

    入力は seed でロードし、変換結果は schema.yml の data test で検証するため、
    外部テーブルに依存せずサンプル単体で実行できます。
#}

with raw_members as (

    -- 意図的に空白、大小文字の揺れ、NULL を含めた変換確認用の seed。
    -- ref を使うことで、dbt build 時に seed がこのモデルより先にロードされます。
    select * from {{ ref('common_transforms_example_source') }}

),

cleaned as (

    select
        -- 元の主キーは後続の確認やトレースに使うため、そのまま保持します。
        member_id,

        -- 数値の member_id を文字列へ変換し、左側を0で埋めて4桁に統一します。
        -- 例: 1 -> '0001'。固定長コードとして出力・結合するときの表記揺れを防ぎます。
        {{ common_transforms.zero_pad('member_id', 4) }} as padded_member_id,

        -- normalize_text で前後空白を除去し、全角スペースを含む連続空白を
        -- 半角スペース1つに圧縮してから、initcap で英字の単語先頭を大文字にします。
        -- 空白だけの入力は normalize_text によって NULL になります。
        {{ common_transforms.change_case(
            common_transforms.normalize_text('member_name'),
            case='initcap'
        ) }} as member_name,

        -- メールアドレスを小文字に統一します。大文字小文字の違いによる
        -- 名寄せや結合の漏れを防ぐため、識別子として扱う前に正規化します。
        {{ common_transforms.change_case('email', case='lower') }} as email,

        -- 会員コードを大文字に統一します。
        -- 例: 'ab-001' -> 'AB-001'。
        {{ common_transforms.change_case('member_code', case='upper') }} as member_code,

        -- 郵便番号の前後に付いた空白を除去します。
        -- normalize_text は途中の連続空白も1つに圧縮し、空文字は NULL にします。
        {{ common_transforms.normalize_text('postal_code') }} as postal_code,

        -- 地域コードが NULL の場合、不明コード '99' で補完します。
        -- 補完理由は region_unknown_reason に残し、data test で入力を必須化します。
        {{ common_transforms.fill_null(
            'region_code',
            default_value='99'
        ) }} as region_code,

        -- 不明コードを設定した理由の空白を正規化します。
        -- schema.yml の placeholder_requires_reason テストにより、region_code = '99' の
        -- 行では、この理由が NULL または空文字になっていないことを検証します。
        {{ common_transforms.normalize_text(
            'region_unknown_reason'
        ) }} as region_unknown_reason,

        -- 注文件数の NULL を数値の0で補完します。
        -- kind='number' を指定することで、文字列ではなく数値リテラルとして展開されます。
        {{ common_transforms.fill_null(
            'order_count',
            kind='number',
            default_value=0
        ) }} as order_count,

        -- 最終ログイン日の補完前に、元データが NULL だったかを保持します。
        -- 補完後の 1900-01-01 と実データを下流で区別するためのフラグです。
        last_login_date is null as is_last_login_date_unknown,

        -- 最終ログイン日の NULL を、dbt_project.yml の epoch_date で補完します。
        -- このプロジェクトでは未指定のため、パッケージ既定値の 1900-01-01 が使われます。
        {{ common_transforms.fill_null(
            'last_login_date',
            kind='date'
        ) }} as last_login_date
    from raw_members

),

final as (

    select
        cleaned.member_id,
        cleaned.padded_member_id,
        cleaned.member_name,
        cleaned.email,
        cleaned.member_code,

        -- dbt 標準の cross-database マクロで、正規化済み会員コードと4桁IDを
        -- ハイフン区切りで結合します。例: 'AB-001' + '-' + '0001' -> 'AB-001-0001'。
        -- schema.yml では dbt_expectations を使い、11文字の完全一致を検証します。
        {{ dbt.concat([
            'cleaned.member_code',
            "'-'",
            'cleaned.padded_member_id'
        ]) }} as member_reference,

        cleaned.postal_code,
        cleaned.region_code,
        cleaned.region_unknown_reason,
        cleaned.order_count,
        cleaned.is_last_login_date_unknown,
        cleaned.last_login_date,

        -- constant は dbt_project.yml の constants から指定した値を1列だけ出力します。
        -- 別名を付けることで、standard_constants の system_code と共存させています。
        {{ common_transforms.constant('system_code') }} as source_system_code,

        -- constants に定義した全項目を、それぞれ同名の列としてまとめて展開します。
        -- この例では created_by、record_type、system_code が追加されます。
        {{ common_transforms.standard_constants() }},

        -- ロード日時、invocation_id、ターゲット名、出力先スキーマを付与します。
        -- データがいつ・どの dbt 実行で作られたかを追跡するための監査列です。
        {{ common_transforms.audit_columns() }}
    from cleaned

)

select * from final
