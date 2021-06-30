data "aws_iam_policy_document" "assume" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }

    actions = [
      "sts:AssumeRole"
    ]
  }
}

resource "aws_iam_role" "lambda" {
  name               = module.this.id
  assume_role_policy = data.aws_iam_policy_document.assume.json
  tags               = module.this.tags
}

data "aws_iam_policy_document" "lambda" {
  statement {
    effect = "Allow"

    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]

    resources = ["*"]
  }

  statement {
    effect = "Allow"

    actions = [
      "ses:SendEmail",
      "ses:SendRawEmail"
    ]

    resources = ["*"]
  }

  statement {
    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:PutObject"
    ]

    resources = ["${aws_s3_bucket.default.arn}/*"]
  }
}

resource "aws_iam_policy" "lambda" {
  name        = module.this.id
  description = "Allow put logs, use s3 to store email and sent emails with SES"
  policy      = data.aws_iam_policy_document.lambda.json
}

resource "aws_iam_role_policy_attachment" "lambda" {
  role       = aws_iam_role.lambda.name
  policy_arn = aws_iam_policy.lambda.arn
}

resource "null_resource" "build_lambda" {
  provisioner "local-exec" {
    working_dir = "${path.module}/lambda"
    command = "npm install"
  }

  triggers = {
    rerun_every_time = "${uuid()}"
  }
}

data "archive_file" "lambda_zip" {
  type = "zip"
  source_dir = "${path.module}/lambda"
  output_path = "${path.module}/build/lambda.zip"

  depends_on = [null_resource.build_lambda]
}

resource "aws_lambda_function" "default" {
  filename         = "${path.module}/build/lambda.zip"
  function_name    = module.this.id
  role             = aws_iam_role.lambda.arn
  handler          = "index.handler"
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  runtime          = var.lambda_runtime
  tags             = module.this.tags

  environment {
    variables = {
      EMAIL_FROM        = var.relay_email
      EMAIL_BUCKET_NAME = aws_s3_bucket.default.bucket
      EMAIL_BUCKET_PATH = ""
      EMAIL_MAPPING     = jsonencode(var.forward_emails)
    }
  }

  tracing_config {
    mode = var.tracing_config_mode
  }
}

resource "aws_lambda_alias" "default" {
  name             = "default"
  description      = "Use latest version as default"
  function_name    = aws_lambda_function.default.function_name
  function_version = "$LATEST"
}

resource "aws_lambda_permission" "ses" {
  statement_id   = "AllowExecutionFromSES"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.default.function_name
  principal      = "ses.amazonaws.com"
  source_account = data.aws_caller_identity.current.account_id
}
