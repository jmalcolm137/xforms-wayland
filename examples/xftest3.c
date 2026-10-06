#include <stdio.h>
#include <forms.h>

static void button_cb(FL_OBJECT *obj, long data)
{
    printf("Hello world\n");
}

int main(int argc, char **argv)
{
    FL_FORM *form;
    FL_OBJECT *obj;

    fl_initialize(&argc, argv, 0, 0, 0);

    form = fl_bgn_form(FL_UP_BOX, 230, 180);
    obj = fl_add_button(FL_NORMAL_BUTTON, 20, 20, 190, 60, "Hello world");
    fl_set_object_callback(obj, button_cb, 0);
    fl_add_button(FL_NORMAL_BUTTON, 70, 100, 90, 60, "Quit");
    fl_end_form();

    fl_show_form(form, FL_PLACE_MOUSE, FL_FULLBORDER, "Hello, world!");

    fl_do_forms();

    fl_do_forms();
    return 0;
}