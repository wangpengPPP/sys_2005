import axios from "axios";
import router from "./../router";
import ElementUI from "element-ui";
axios.defaults.baseURL =
  process.env.NODE_ENV === "development" ? "/api" : "http://www.chst.vip";
axios.defaults.withCredentials = true; //允许请求携带认证
//创建请求拦截器
axios.interceptors.request.use(config => {
  //登陆注册是不需要token的
  // console.log(config);
  if (config.url == "/users/login") {
    return config;
  } else {
    let token = localStorage.getItem("qf2005-token");
    config.headers["authorization"] = token;
    return config;
  }
});
//响应拦截
axios.interceptors.response.use(config => {
  console.log(config);
  let { data } = config;
  if (data.code == "1004" || data.code == "10022") {
    ElementUI.Message.error("登录失效");
    router.push("/login");
  }
  return config;
});
axios.create({
  timeout: 4000
});
export default axios;
