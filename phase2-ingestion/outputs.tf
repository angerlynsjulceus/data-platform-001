output "kinesis_stream_name" {
  value = aws_kinesis_stream.sales.name
}

output "kinesis_stream_arn" {
  value = aws_kinesis_stream.sales.arn
}

output "ec2_public_ip" {
  value = aws_instance.simulator.public_ip
}

output "ec2_iam_role_arn" {
  value = aws_iam_role.simulator.arn
}

output "key_pair_name" {
  value = aws_key_pair.capstone.key_name
}

output "ssh_command" {
  value = "ssh -i C:\\terraform\\key-pair\\capstone.pem ec2-user@${aws_instance.simulator.public_ip}"
}
