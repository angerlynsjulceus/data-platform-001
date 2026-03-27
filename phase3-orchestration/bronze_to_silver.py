import sys
from awsglue.transforms import *
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from awsglue.context import GlueContext
from awsglue.job import Job
from pyspark.sql.types import (
    StructType, StructField, StringType,
    TimestampType, IntegerType, DoubleType
)

args = getResolvedOptions(sys.argv, ["JOB_NAME", "bronze_path", "silver_path"])
sc   = SparkContext()
glue = GlueContext(sc)
job  = Job(glue)
job.init(args["JOB_NAME"], args)

schema = StructType([
    StructField("transaction_id", StringType(),    True),
    StructField("timestamp",      TimestampType(), True),
    StructField("product",        StringType(),    True),
    StructField("quantity",       IntegerType(),   True),
    StructField("unit_price",     DoubleType(),    True),
    StructField("region",         StringType(),    True),
    StructField("store_id",       StringType(),    True),
])

df = glue.spark_session.read \
    .option("multiline", "true") \
    .schema(schema) \
    .json(args["bronze_path"])

df.write \
    .mode("overwrite") \
    .option("compression", "snappy") \
    .parquet(args["silver_path"])

job.commit()
