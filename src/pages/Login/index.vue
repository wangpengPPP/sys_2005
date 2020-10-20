<template>
  <div class="about">
    <video id="bgvid" autoplay muted loop>
      <source src="../../123.mp4" type="video/mp4" />
    </video>
    <el-form
      :model="ruleForm"
      status-icon
      :rules="rules"
      ref="ruleForm"
      label-width="100px"
      class="demo-ruleForm"
    >
      <h1 style="display:flex;justify-content:center">管理系统登陆</h1>
      <el-form-item label="用户名" prop="username">
        <el-input
          type="text"
          v-model="ruleForm.username"
          autocomplete="off"
        ></el-input>
      </el-form-item>
      <el-form-item label="密码" prop="password">
        <el-input
          type="password"
          v-model="ruleForm.password"
          autocomplete="off"
        ></el-input>
      </el-form-item>
      <el-form-item>
        <el-button type="primary" @click="submitForm('ruleForm')"
          >提交</el-button
        >
      </el-form-item>
    </el-form>
  </div>
</template>
<script>
export default {
  data() {
    var validateUsername = (rule, value, callback) => {
      // console.log(rule);
      // console.log(value);
      if (!value) {
        callback("请输入用户名");
      } else {
        callback();
      }
      // if (value === '') {
      //   callback(new Error('请输入用户名'));
      // } else {
      //   if (this.ruleForm.username !== '') {
      //     this.$refs.ruleForm.validateField('password');
      //   }
      //   callback();
      // }
    };
    var validatePass = (rule, value, callback) => {
      // console.log(value);
      if (!value) {
        callback("请输入密码");
      } else {
        callback();
      }
    };
    return {
      ruleForm: {
        username: "",
        password: ""
      },
      rules: {
        username: [{ validator: validateUsername, trigger: "blur" }],
        password: [{ validator: validatePass, trigger: "blur" }]
      }
    };
  },
  methods: {
    submitForm(formName) {
      console.log(this.ruleForm);
      console.log(this.$refs);
      console.log(this.$refs[formName]);
      console.log(this.$refs.ruleForm.validate());
      this.$refs[formName].validate(valid => {
        if (valid) {
          alert("submit!");
        } else {
          console.log("error submit!!");
          return false;
        }
      });
    }
  }
};
</script>
<style scoped>
.about {
  width: 400px;
  position: absolute;
  right: 150px;
  top: 200px;
}
.el-form {
  width: 400px;
  height: 250px;
}
#bgvid {
  position: fixed;
  right: 0;
  bottom: 0;
  min-width: 100%;
  min-height: 100%;
  width: auto;
  height: auto;
  z-index: -100;
  background-size: cover;
}
</style>
