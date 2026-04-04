from django import forms
from django.contrib.auth.forms import AuthenticationForm, UserCreationForm
from django.contrib.auth.models import User


class MeetingAuthenticationForm(AuthenticationForm):
    username = forms.CharField(
        label="用户名",
        widget=forms.TextInput(attrs={"class": "auth-input", "placeholder": "请输入用户名"}),
    )
    password = forms.CharField(
        label="密码",
        widget=forms.PasswordInput(attrs={"class": "auth-input", "placeholder": "请输入密码"}),
    )


class MeetingRegisterForm(UserCreationForm):
    email = forms.EmailField(
        label="邮箱",
        widget=forms.EmailInput(attrs={"class": "auth-input", "placeholder": "请输入邮箱"}),
    )

    class Meta:
        model = User
        fields = ("username", "email", "password1", "password2")
        widgets = {
            "username": forms.TextInput(attrs={"class": "auth-input", "placeholder": "3-50 位用户名"}),
        }

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.fields["password1"].widget.attrs.update(
            {"class": "auth-input", "placeholder": "至少 8 位，建议包含字母和数字"},
        )
        self.fields["password2"].widget.attrs.update(
            {"class": "auth-input", "placeholder": "再次输入密码"},
        )
